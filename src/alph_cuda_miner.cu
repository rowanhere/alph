#include <cuda_runtime.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
using socket_t = SOCKET;
static constexpr socket_t INVALID_SOCKET_T = INVALID_SOCKET;
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <unistd.h>
using socket_t = int;
static constexpr socket_t INVALID_SOCKET_T = -1;
#endif

#define MAX_HEADER_BYTES 256

static __constant__ uint8_t C_HEADER[MAX_HEADER_BYTES];
static __constant__ uint8_t C_TARGET[32];
static __constant__ uint8_t C_EXTRA_NONCE[32];

static __device__ __forceinline__ uint32_t rotr32(uint32_t x, int n) {
    return (x >> n) | (x << (32 - n));
}

static __device__ __forceinline__ uint32_t load32_le(const uint8_t *p) {
    return ((uint32_t)p[0]) | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static __device__ __forceinline__ void store64_be(uint8_t *p, uint64_t v, uint32_t bytes) {
    for (uint32_t i = 0; i < bytes; ++i) {
        p[bytes - 1 - i] = (uint8_t)(v >> (i * 8));
    }
}

static __device__ __forceinline__ void store32_le(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static __device__ __forceinline__ void g(uint32_t v[16], int a, int b, int c, int d, uint32_t x, uint32_t y) {
    v[a] = v[a] + v[b] + x;
    v[d] = rotr32(v[d] ^ v[a], 16);
    v[c] = v[c] + v[d];
    v[b] = rotr32(v[b] ^ v[c], 12);
    v[a] = v[a] + v[b] + y;
    v[d] = rotr32(v[d] ^ v[a], 8);
    v[c] = v[c] + v[d];
    v[b] = rotr32(v[b] ^ v[c], 7);
}

static __device__ void blake3_compress(
    const uint32_t cv[8],
    const uint8_t block[64],
    uint8_t block_len,
    uint64_t counter,
    uint8_t flags,
    uint32_t out[16]
) {
    static constexpr uint32_t IV[8] = {
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    };
    static constexpr uint8_t MSG_PERMUTATION[16] = {
        2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8
    };

    uint32_t m[16];
    #pragma unroll
    for (int i = 0; i < 16; ++i) {
        m[i] = load32_le(block + i * 4);
    }

    uint32_t v[16];
    #pragma unroll
    for (int i = 0; i < 8; ++i) v[i] = cv[i];
    #pragma unroll
    for (int i = 0; i < 8; ++i) v[i + 8] = IV[i];
    v[12] ^= (uint32_t)counter;
    v[13] ^= (uint32_t)(counter >> 32);
    v[14] ^= (uint32_t)block_len;
    v[15] ^= (uint32_t)flags;

    #pragma unroll
    for (int round = 0; round < 7; ++round) {
        g(v, 0, 4, 8, 12, m[0], m[1]);
        g(v, 1, 5, 9, 13, m[2], m[3]);
        g(v, 2, 6, 10, 14, m[4], m[5]);
        g(v, 3, 7, 11, 15, m[6], m[7]);
        g(v, 0, 5, 10, 15, m[8], m[9]);
        g(v, 1, 6, 11, 12, m[10], m[11]);
        g(v, 2, 7, 8, 13, m[12], m[13]);
        g(v, 3, 4, 9, 14, m[14], m[15]);

        uint32_t old[16];
        #pragma unroll
        for (int i = 0; i < 16; ++i) old[i] = m[i];
        #pragma unroll
        for (int i = 0; i < 16; ++i) m[i] = old[MSG_PERMUTATION[i]];
    }

    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        out[i] = v[i] ^ v[i + 8];
        out[i + 8] = v[i + 8] ^ cv[i];
    }
}

static __device__ void blake3_hash_small(const uint8_t *input, uint32_t len, uint8_t out[32]) {
    static constexpr uint32_t IV[8] = {
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    };
    static constexpr uint8_t CHUNK_START = 1;
    static constexpr uint8_t CHUNK_END = 2;
    static constexpr uint8_t ROOT = 8;

    uint32_t cv[8];
    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = IV[i];

    uint32_t offset = 0;
    bool first = true;
    while (offset < len || (len == 0 && first)) {
        uint8_t block[64];
        #pragma unroll
        for (int i = 0; i < 64; ++i) block[i] = 0;

        uint32_t remaining = len - offset;
        uint32_t take = remaining < 64u ? remaining : 64u;
        for (uint32_t i = 0; i < take; ++i) block[i] = input[offset + i];

        uint8_t flags = 0;
        if (first) flags |= CHUNK_START;
        if (offset + take >= len) flags |= CHUNK_END | ROOT;

        uint32_t words[16];
        blake3_compress(cv, block, (uint8_t)take, 0, flags, words);

        if (offset + take >= len) {
            #pragma unroll
            for (int i = 0; i < 8; ++i) store32_le(out + i * 4, words[i]);
            return;
        }

        #pragma unroll
        for (int i = 0; i < 8; ++i) cv[i] = words[i];
        offset += take;
        first = false;
    }
}

static __device__ bool meets_target(const uint8_t hash[32], bool target_big_endian) {
    if (target_big_endian) {
        for (int i = 0; i < 32; ++i) {
            if (hash[i] < C_TARGET[i]) return true;
            if (hash[i] > C_TARGET[i]) return false;
        }
        return true;
    }

    for (int i = 31; i >= 0; --i) {
        if (hash[i] < C_TARGET[i]) return true;
        if (hash[i] > C_TARGET[i]) return false;
    }
    return true;
}

enum NonceMode : int {
    NONCE_REPLACE_TAIL = 0,
    NONCE_REPLACE_AT = 1,
    NONCE_APPEND = 2
};

__global__ void alph_mine_kernel(
    uint32_t header_len,
    uint32_t extra_len,
    uint32_t nonce_total_len,
    uint32_t nonce_sans_len,
    int nonce_mode,
    uint32_t nonce_offset,
    bool target_big_endian,
    uint64_t start_nonce,
    uint64_t total_nonces,
    unsigned long long *found_nonce,
    int *found_flag
) {
    uint64_t index = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t stride = (uint64_t)gridDim.x * blockDim.x;
    uint32_t poll = 0;

    for (; index < total_nonces; index += stride) {
        if ((poll++ & 255u) == 0 && *(volatile int *)found_flag != 0) return;

        uint8_t msg[MAX_HEADER_BYTES];
        #pragma unroll
        for (int i = 0; i < MAX_HEADER_BYTES; ++i) msg[i] = 0;

        for (uint32_t i = 0; i < header_len && i < MAX_HEADER_BYTES; ++i) {
            msg[i] = C_HEADER[i];
        }

        uint64_t nonce = start_nonce + index;
        uint8_t nonce_field[32];
        #pragma unroll
        for (int i = 0; i < 32; ++i) nonce_field[i] = 0;
        for (uint32_t i = 0; i < extra_len && i < 32; ++i) nonce_field[i] = C_EXTRA_NONCE[i];
        store64_be(nonce_field + extra_len, nonce, nonce_sans_len);

        uint32_t out_len = header_len;
        uint32_t offset = nonce_offset;
        if (nonce_mode == NONCE_REPLACE_TAIL) {
            offset = header_len >= nonce_total_len ? header_len - nonce_total_len : 0;
        } else if (nonce_mode == NONCE_APPEND) {
            offset = header_len;
            out_len = header_len + nonce_total_len;
        }

        if (offset + nonce_total_len > MAX_HEADER_BYTES || out_len > MAX_HEADER_BYTES) return;
        for (uint32_t i = 0; i < nonce_total_len; ++i) msg[offset + i] = nonce_field[i];

        uint8_t hash[32];
        blake3_hash_small(msg, out_len, hash);

        if (meets_target(hash, target_big_endian)) {
            if (atomicCAS(found_flag, 0, 1) == 0) {
                *found_nonce = (unsigned long long)nonce;
            }
            return;
        }
    }
}

struct Config {
    std::string url = "stratum+tcp://us.icminers.com:9160";
    std::string user;
    std::string pass = "x";
    std::string config_path;
    int device = 0;
    uint64_t batch = 16777216ULL;
    int threads = 256;
    int blocks = 0;
    uint32_t nonce_bytes = 24;
    uint32_t nonce_sans_bytes = 8;
    std::string nonce_mode = "replace-tail";
    uint32_t nonce_offset = 0;
    bool target_big_endian = true;
};

struct Job {
    std::string id;
    std::string chain_index;
    std::vector<uint8_t> header;
    std::vector<uint8_t> target;
    std::vector<uint8_t> extra_nonce;
    std::string worker_id;
    bool ready = false;
};

static void close_socket(socket_t s) {
#ifdef _WIN32
    closesocket(s);
#else
    close(s);
#endif
}

static std::string trim(const std::string &s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

static bool starts_with(const std::string &s, const std::string &prefix) {
    return s.rfind(prefix, 0) == 0;
}

static std::vector<uint8_t> hex_to_bytes(std::string hex) {
    hex = trim(hex);
    if (starts_with(hex, "0x")) hex = hex.substr(2);
    if (hex.size() % 2 != 0) hex = "0" + hex;
    std::vector<uint8_t> out;
    out.reserve(hex.size() / 2);
    for (size_t i = 0; i < hex.size(); i += 2) {
        char a = hex[i];
        char b = hex[i + 1];
        if (!std::isxdigit((unsigned char)a) || !std::isxdigit((unsigned char)b)) {
            throw std::runtime_error("invalid hex string: " + hex);
        }
        out.push_back((uint8_t)std::stoul(hex.substr(i, 2), nullptr, 16));
    }
    return out;
}

static std::vector<uint8_t> target_from_difficulty(double difficulty) {
    if (difficulty <= 0.0 || !std::isfinite(difficulty)) {
        throw std::runtime_error("invalid pool difficulty");
    }

    uint64_t divisor = (uint64_t)std::ceil(difficulty);
    if (divisor == 0) divisor = 1;

    std::vector<uint8_t> target(32, 0xff);
    uint64_t remainder = 0;
    for (uint8_t &byte : target) {
        uint64_t value = (remainder << 8) | byte;
        byte = (uint8_t)(value / divisor);
        remainder = value % divisor;
    }
    return target;
}

static std::string nonce_to_hex(uint64_t nonce, uint32_t bytes) {
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (int i = (int)bytes - 1; i >= 0; --i) {
        out << std::setw(2) << ((nonce >> (i * 8)) & 0xff);
    }
    return out.str();
}

static void parse_url(const std::string &url, std::string &host, std::string &port) {
    std::string s = url;
    const std::string prefix = "stratum+tcp://";
    if (starts_with(s, prefix)) s = s.substr(prefix.size());
    size_t slash = s.find('/');
    if (slash != std::string::npos) s = s.substr(0, slash);
    size_t colon = s.rfind(':');
    if (colon == std::string::npos) throw std::runtime_error("pool URL must include :PORT");
    host = s.substr(0, colon);
    port = s.substr(colon + 1);
}

static socket_t connect_tcp(const std::string &host, const std::string &port) {
#ifdef _WIN32
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) throw std::runtime_error("WSAStartup failed");
#endif
    addrinfo hints{};
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    addrinfo *res = nullptr;
    int rc = getaddrinfo(host.c_str(), port.c_str(), &hints, &res);
    if (rc != 0) throw std::runtime_error("DNS lookup failed for " + host + ":" + port);

    socket_t sock = INVALID_SOCKET_T;
    for (addrinfo *p = res; p; p = p->ai_next) {
        sock = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (sock == INVALID_SOCKET_T) continue;
        if (connect(sock, p->ai_addr, (int)p->ai_addrlen) == 0) break;
        close_socket(sock);
        sock = INVALID_SOCKET_T;
    }
    freeaddrinfo(res);
    if (sock == INVALID_SOCKET_T) throw std::runtime_error("TCP connect failed");
    return sock;
}

static void send_line(socket_t sock, const std::string &line) {
    std::string wire = line + "\n";
    const char *p = wire.c_str();
    size_t left = wire.size();
    while (left > 0) {
        int sent = send(sock, p, (int)left, 0);
        if (sent <= 0) throw std::runtime_error("socket send failed");
        p += sent;
        left -= (size_t)sent;
    }
}

static bool recv_line(socket_t sock, std::string &buffer, std::string &line) {
    for (;;) {
        size_t nl = buffer.find('\n');
        if (nl != std::string::npos) {
            line = buffer.substr(0, nl);
            buffer.erase(0, nl + 1);
            line = trim(line);
            return true;
        }
        char tmp[4096];
        int got = recv(sock, tmp, sizeof(tmp), 0);
        if (got <= 0) return false;
        buffer.append(tmp, tmp + got);
    }
}

static bool socket_has_data(socket_t sock) {
    fd_set readfds;
    FD_ZERO(&readfds);
    FD_SET(sock, &readfds);
    timeval tv{};
    tv.tv_sec = 0;
    tv.tv_usec = 0;
    int rc = select((int)(sock + 1), &readfds, nullptr, nullptr, &tv);
    return rc > 0 && FD_ISSET(sock, &readfds);
}

static std::string json_escape(const std::string &s) {
    std::string out;
    for (char c : s) {
        if (c == '"' || c == '\\') out.push_back('\\');
        out.push_back(c);
    }
    return out;
}

static std::string get_json_string_field(const std::string &json, const std::string &field) {
    std::string key = "\"" + field + "\"";
    size_t p = json.find(key);
    if (p == std::string::npos) return "";
    p = json.find(':', p);
    if (p == std::string::npos) return "";
    p = json.find_first_not_of(" \t\r\n", p + 1);
    if (p == std::string::npos || json[p] != '"') return "";
    size_t e = p + 1;
    while (true) {
        e = json.find('"', e);
        if (e == std::string::npos) return "";
        if (json[e - 1] != '\\') break;
        ++e;
    }
    return json.substr(p + 1, e - p - 1);
}

static std::string get_method(const std::string &json) {
    return get_json_string_field(json, "method");
}

static std::string params_substring(const std::string &json) {
    size_t p = json.find("\"params\"");
    if (p == std::string::npos) return "";
    p = json.find(':', p);
    if (p == std::string::npos) return "";
    size_t start = json.find_first_not_of(" \t\r\n", p + 1);
    if (start == std::string::npos) return "";
    if (json[start] != '[' && json[start] != '{') {
        size_t end = json.find_first_of(",}", start);
        return json.substr(start, end - start);
    }
    char open = json[start];
    char close = open == '[' ? ']' : '}';
    int depth = 0;
    bool in_string = false;
    for (size_t i = start; i < json.size(); ++i) {
        char c = json[i];
        if (c == '"' && (i == 0 || json[i - 1] != '\\')) in_string = !in_string;
        if (in_string) continue;
        if (c == open) ++depth;
        if (c == close) {
            --depth;
            if (depth == 0) return json.substr(start, i - start + 1);
        }
    }
    return "";
}

static std::vector<std::string> json_strings_in(const std::string &s) {
    std::vector<std::string> out;
    for (size_t p = 0; p < s.size();) {
        p = s.find('"', p);
        if (p == std::string::npos) break;
        size_t e = p + 1;
        while (true) {
            e = s.find('"', e);
            if (e == std::string::npos) return out;
            if (s[e - 1] != '\\') break;
            ++e;
        }
        out.push_back(s.substr(p + 1, e - p - 1));
        p = e + 1;
    }
    return out;
}

static bool looks_like_hex(const std::string &s) {
    std::string v = s;
    if (starts_with(v, "0x")) v = v.substr(2);
    if (v.empty()) return false;
    for (char c : v) {
        if (!std::isxdigit((unsigned char)c)) return false;
    }
    return true;
}

static std::string first_present_json_string_field(const std::string &json, const std::vector<std::string> &fields) {
    for (const std::string &field : fields) {
        std::string value = get_json_string_field(json, field);
        if (!value.empty()) return value;
    }
    return "";
}

static bool first_json_number_in_params(const std::string &json, double &value) {
    std::string params = params_substring(json);
    size_t p = params.find_first_of("-0123456789");
    if (p == std::string::npos) return false;
    size_t e = params.find_first_not_of("0123456789.eE+-", p);
    try {
        value = std::stod(params.substr(p, e == std::string::npos ? std::string::npos : e - p));
        return true;
    } catch (...) {
        return false;
    }
}

static int nonce_mode_value(const std::string &mode) {
    if (mode == "replace-tail") return NONCE_REPLACE_TAIL;
    if (mode == "replace-at") return NONCE_REPLACE_AT;
    if (mode == "append") return NONCE_APPEND;
    throw std::runtime_error("bad --nonce-mode: " + mode);
}

static void check_cuda(cudaError_t err, const char *what) {
    if (err != cudaSuccess) {
        throw std::runtime_error(std::string(what) + ": " + cudaGetErrorString(err));
    }
}

struct MineResult {
    bool found = false;
    uint64_t nonce = 0;
    double seconds = 0.0;
};

static MineResult mine_batch(const Config &cfg, const Job &job, uint64_t start_nonce, int blocks) {
    if (job.header.size() > MAX_HEADER_BYTES) throw std::runtime_error("header too large for this miner");
    if (job.extra_nonce.size() > 32) throw std::runtime_error("extraNonce too large");
    if (cfg.nonce_bytes > 32 || cfg.nonce_sans_bytes > 8) throw std::runtime_error("nonce sizing too large");
    if (job.extra_nonce.size() + cfg.nonce_sans_bytes > cfg.nonce_bytes) {
        throw std::runtime_error("extraNonce + nonceSansExtraNonce exceeds nonce field length");
    }

    uint8_t header[MAX_HEADER_BYTES]{};
    std::copy(job.header.begin(), job.header.end(), header);
    uint8_t target[32]{};
    if (job.target.empty()) throw std::runtime_error("missing target");
    if (job.target.size() >= 32) {
        if (cfg.target_big_endian) {
            std::copy(job.target.end() - 32, job.target.end(), target);
        } else {
            std::copy(job.target.begin(), job.target.begin() + 32, target);
        }
    } else if (cfg.target_big_endian) {
        std::copy(job.target.begin(), job.target.end(), target + (32 - job.target.size()));
    } else {
        std::copy(job.target.begin(), job.target.end(), target);
    }
    uint8_t extra[32]{};
    std::copy(job.extra_nonce.begin(), job.extra_nonce.end(), extra);

    check_cuda(cudaMemcpyToSymbol(C_HEADER, header, sizeof(header)), "copy header");
    check_cuda(cudaMemcpyToSymbol(C_TARGET, target, sizeof(target)), "copy target");
    check_cuda(cudaMemcpyToSymbol(C_EXTRA_NONCE, extra, sizeof(extra)), "copy extraNonce");

    unsigned long long *d_nonce = nullptr;
    int *d_flag = nullptr;
    check_cuda(cudaMalloc((void **)&d_nonce, sizeof(unsigned long long)), "malloc nonce");
    check_cuda(cudaMalloc((void **)&d_flag, sizeof(int)), "malloc flag");
    unsigned long long zero_nonce = 0;
    int zero = 0;
    check_cuda(cudaMemcpy(d_nonce, &zero_nonce, sizeof(zero_nonce), cudaMemcpyHostToDevice), "init nonce");
    check_cuda(cudaMemcpy(d_flag, &zero, sizeof(zero), cudaMemcpyHostToDevice), "init flag");

    auto started = std::chrono::steady_clock::now();
    alph_mine_kernel<<<blocks, cfg.threads>>>(
        (uint32_t)job.header.size(),
        (uint32_t)job.extra_nonce.size(),
        cfg.nonce_bytes,
        cfg.nonce_sans_bytes,
        nonce_mode_value(cfg.nonce_mode),
        cfg.nonce_offset,
        cfg.target_big_endian,
        start_nonce,
        cfg.batch,
        d_nonce,
        d_flag
    );
    check_cuda(cudaGetLastError(), "kernel launch");
    check_cuda(cudaDeviceSynchronize(), "kernel sync");
    auto ended = std::chrono::steady_clock::now();

    int h_flag = 0;
    unsigned long long h_nonce = 0;
    check_cuda(cudaMemcpy(&h_flag, d_flag, sizeof(h_flag), cudaMemcpyDeviceToHost), "read flag");
    check_cuda(cudaMemcpy(&h_nonce, d_nonce, sizeof(h_nonce), cudaMemcpyDeviceToHost), "read nonce");
    cudaFree(d_nonce);
    cudaFree(d_flag);

    MineResult result;
    result.found = h_flag != 0;
    result.nonce = (uint64_t)h_nonce;
    result.seconds = std::chrono::duration<double>(ended - started).count();
    return result;
}

static void load_config_file(Config &cfg, const std::string &path) {
    std::ifstream in(path);
    if (!in) throw std::runtime_error("cannot open config: " + path);
    std::string line;
    while (std::getline(in, line)) {
        line = trim(line);
        if (line.empty() || line[0] == '#') continue;
        size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string k = trim(line.substr(0, eq));
        std::string v = trim(line.substr(eq + 1));
        if (k == "url") cfg.url = v;
        else if (k == "user") cfg.user = v;
        else if (k == "pass") cfg.pass = v;
        else if (k == "device") cfg.device = std::stoi(v);
        else if (k == "batch") cfg.batch = std::stoull(v);
        else if (k == "threads") cfg.threads = std::stoi(v);
        else if (k == "blocks") cfg.blocks = std::stoi(v);
        else if (k == "nonce-bytes") cfg.nonce_bytes = (uint32_t)std::stoul(v);
        else if (k == "nonce-sans-bytes") cfg.nonce_sans_bytes = (uint32_t)std::stoul(v);
        else if (k == "nonce-mode") cfg.nonce_mode = v;
        else if (k == "nonce-offset") cfg.nonce_offset = (uint32_t)std::stoul(v);
        else if (k == "target-order") cfg.target_big_endian = (v != "le");
    }
}

static Config parse_args(int argc, char **argv) {
    Config cfg;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto need = [&](const char *name) -> std::string {
            if (i + 1 >= argc) throw std::runtime_error(std::string("missing value for ") + name);
            return argv[++i];
        };
        if (a == "-c" || a == "--config") {
            cfg.config_path = need(a.c_str());
            load_config_file(cfg, cfg.config_path);
        } else if (a == "-o" || a == "--url") cfg.url = need(a.c_str());
        else if (a == "-u" || a == "--user") cfg.user = need(a.c_str());
        else if (a == "-p" || a == "--pass") cfg.pass = need(a.c_str());
        else if (a == "--device") cfg.device = std::stoi(need(a.c_str()));
        else if (a == "--batch") cfg.batch = std::stoull(need(a.c_str()));
        else if (a == "--threads") cfg.threads = std::stoi(need(a.c_str()));
        else if (a == "--blocks") cfg.blocks = std::stoi(need(a.c_str()));
        else if (a == "--nonce-bytes") cfg.nonce_bytes = (uint32_t)std::stoul(need(a.c_str()));
        else if (a == "--nonce-sans-bytes") cfg.nonce_sans_bytes = (uint32_t)std::stoul(need(a.c_str()));
        else if (a == "--nonce-mode") cfg.nonce_mode = need(a.c_str());
        else if (a == "--nonce-offset") cfg.nonce_offset = (uint32_t)std::stoul(need(a.c_str()));
        else if (a == "--target-order") {
            std::string v = need(a.c_str());
            cfg.target_big_endian = (v != "le");
        } else if (a == "-h" || a == "--help") {
            std::cout << "Usage: alph-cuda-miner -o stratum+tcp://host:port -u WALLET.worker -p x [options]\n";
            std::exit(0);
        } else {
            throw std::runtime_error("unknown argument: " + a);
        }
    }
    if (cfg.user.empty()) throw std::runtime_error("missing -u WALLET.worker");
    return cfg;
}

static std::string request(int id, const std::string &method, const std::string &params) {
    std::ostringstream out;
    out << "{\"id\":\"" << id << "\",\"method\":\"" << method << "\"";
    if (!params.empty()) out << ",\"params\":" << params;
    out << "}";
    return out.str();
}

static void handle_message(const std::string &line, Job &job) {
    std::string method = get_method(line);
    if (method == "mining.set_extranonce") {
        auto vals = json_strings_in(params_substring(line));
        if (!vals.empty()) {
            job.extra_nonce = hex_to_bytes(vals[0]);
            std::cout << "[STRATUM] extraNonce " << vals[0] << "\n";
        }
    } else if (method == "mining.set_target") {
        auto vals = json_strings_in(params_substring(line));
        if (!vals.empty()) {
            job.target = hex_to_bytes(vals[0]);
            std::cout << "[STRATUM] target " << vals[0] << "\n";
        }
    } else if (method == "mining.set_difficulty") {
        double difficulty = 0.0;
        if (first_json_number_in_params(line, difficulty)) {
            job.target = target_from_difficulty(difficulty);
            std::cout << "[STRATUM] difficulty " << difficulty << "\n";
        }
    } else if (method == "mining.notify") {
        std::string params = params_substring(line);
        std::string job_id = first_present_json_string_field(params, {"jobId", "job_id", "id"});
        std::string header_hex = first_present_json_string_field(params, {"header", "headerBlob", "blob", "blockHeader"});
        std::string chain_index = first_present_json_string_field(params, {"chainIndex", "chain_index"});

        if (header_hex.empty()) {
            auto vals = json_strings_in(params);
            std::vector<std::string> values;
            for (const std::string &value : vals) {
                if (value == "jobId" || value == "job_id" || value == "id" ||
                    value == "fromGroup" || value == "toGroup" ||
                    value == "chainIndex" || value == "chain_index" ||
                    value == "header" || value == "headerBlob" ||
                    value == "blob" || value == "blockHeader") {
                    continue;
                }
                values.push_back(value);
            }

            for (const std::string &value : values) {
                if (looks_like_hex(value) && value.size() >= 64) {
                    header_hex = value;
                    break;
                }
            }
            if (job_id.empty() && !values.empty()) {
                job_id = values[0];
            }
            if (chain_index.empty() && values.size() > 1) {
                chain_index = values[1];
            }
        }

        if (!header_hex.empty()) {
            try {
                job.id = job_id.empty() ? job.id : job_id;
                job.chain_index = chain_index;
                job.header = hex_to_bytes(header_hex);
                job.ready = !job.target.empty();
                std::cout << "[STRATUM] job=" << job.id
                          << " chain=" << job.chain_index
                          << " header=" << job.header.size() << " bytes\n";
            } catch (const std::exception &err) {
                std::cerr << "[STRATUM] ignored bad job header: " << err.what()
                          << " raw=" << line << "\n";
            }
        } else {
            std::cerr << "[STRATUM] ignored notify without header raw=" << line << "\n";
        }
    } else if (line.find("\"id\":\"3\"") != std::string::npos || line.find("\"id\":3") != std::string::npos) {
        std::string result = get_json_string_field(line, "result");
        if (!result.empty()) {
            job.worker_id = result;
            std::cout << "[STRATUM] workerId " << result << "\n";
        }
    } else if (line.find("\"id\"") != std::string::npos && line.find("\"result\"") != std::string::npos) {
        std::cout << "[STRATUM] " << line << "\n";
    } else if (!line.empty()) {
        std::cout << "[STRATUM] " << line << "\n";
    }
}

int main(int argc, char **argv) {
    try {
        Config cfg = parse_args(argc, argv);
        check_cuda(cudaSetDevice(cfg.device), "set CUDA device");

        cudaDeviceProp prop{};
        check_cuda(cudaGetDeviceProperties(&prop, cfg.device), "get CUDA device");
        int blocks = cfg.blocks > 0 ? cfg.blocks : prop.multiProcessorCount * 8;

        std::string host, port;
        parse_url(cfg.url, host, port);
        std::cout << "[CONFIG] pool=" << cfg.url << " user=" << cfg.user << "\n";
        std::cout << "[CUDA] device=" << cfg.device << " " << prop.name
                  << " blocks=" << blocks << " threads=" << cfg.threads
                  << " batch=" << cfg.batch << "\n";
        std::cout << "[ALPH] nonce-mode=" << cfg.nonce_mode
                  << " nonce-bytes=" << cfg.nonce_bytes
                  << " nonceSans=" << cfg.nonce_sans_bytes
                  << " target-order=" << (cfg.target_big_endian ? "be" : "le") << "\n";

        socket_t sock = connect_tcp(host, port);
        std::cout << "[STRATUM] connected to " << host << ":" << port << "\n";

        send_line(sock, request(0, "mining.hello", "[\"alph-cuda-miner/0.1\",\"AlephiumStratum/1.0.0\"]"));
        send_line(sock, request(2, "mining.subscribe", "[]"));
        send_line(sock, request(3, "mining.authorize", "[\"" + json_escape(cfg.user) + "\",\"" + json_escape(cfg.pass) + "\"]"));

        std::string rx;
        Job job;
        uint64_t start_nonce = (uint64_t)std::chrono::high_resolution_clock::now().time_since_epoch().count();
        uint64_t total_hashes = 0;
        auto miner_started = std::chrono::steady_clock::now();

        std::string line;
        while (!job.ready) {
            if (!recv_line(sock, rx, line)) {
                throw std::runtime_error("pool disconnected before a mineable job arrived");
            }
            handle_message(line, job);
        }

        while (true) {
            while (socket_has_data(sock) && recv_line(sock, rx, line)) {
                handle_message(line, job);
            }

            auto result = mine_batch(cfg, job, start_nonce, blocks);
            total_hashes += cfg.batch;
            double rate = cfg.batch / std::max(result.seconds, 0.001);
            double avg = total_hashes / std::max(
                std::chrono::duration<double>(std::chrono::steady_clock::now() - miner_started).count(),
                0.001
            );
            std::cout << "[MINER] " << std::fixed << std::setprecision(2)
                      << (rate / 1000000.0) << " MH/s current, "
                      << (avg / 1000000.0) << " MH/s avg, job=" << job.id << "\n";

            if (result.found) {
                std::string nonce_hex = nonce_to_hex(result.nonce, cfg.nonce_sans_bytes);
                std::ostringstream params;
                params << "[\"" << json_escape(job.id) << "\",\"" << nonce_hex << "\"";
                if (!job.worker_id.empty()) params << ",\"" << json_escape(job.worker_id) << "\"";
                params << "]";
                send_line(sock, request(4, "mining.submit", params.str()));
                std::cout << "[SHARE] submitted job=" << job.id << " nonceSansExtraNonce=" << nonce_hex << "\n";
            }

            start_nonce += cfg.batch;
        }
    } catch (const std::exception &err) {
        std::cerr << "[ERROR] " << err.what() << "\n";
        return 1;
    }
}
