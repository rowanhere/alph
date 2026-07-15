# ALPH CUDA Miner

Experimental Alephium (ALPH) Stratum miner for NVIDIA CUDA GPUs.

This project is intentionally separate from the existing QL miner. It targets
the official Alephium Stratum flow:

- `mining.hello`
- `mining.subscribe`
- `mining.authorize`
- `mining.set_extranonce`
- `mining.set_target`
- `mining.notify`
- `mining.submit`

ICMiners ALPH shared ports from their public pool API:

```text
stratum+tcp://us.icminers.com:9060
stratum+tcp://us.icminers.com:9160
stratum+tcp://us.icminers.com:9161
```

Solo ports:

```text
stratum+tcp://us.icminers.com:9162
stratum+tcp://us.icminers.com:9163
```

## Ubuntu Build

Install the NVIDIA driver and CUDA toolkit first. `nvidia-smi` and
`nvcc --version` should work.

Ubuntu quick build:

```bash
sudo apt update
sudo apt install -y build-essential nvidia-cuda-toolkit
cd alph-cuda-miner
chmod +x build-ubuntu.sh run-icminers-ubuntu.sh run-icminers-multigpu-ubuntu.sh
./build-ubuntu.sh
```

If you know your GPU architecture, pass it as `CUDA_ARCH`:

```bash
CUDA_ARCH=sm_89 ./build-ubuntu.sh
```

Common NVIDIA architectures:

```text
RTX 20xx: sm_75
RTX 30xx: sm_86
RTX 40xx: sm_89
RTX 50xx: check your installed CUDA docs
```

## Manual Build

Direct build:

```bash
cd alph-cuda-miner
nvcc -O3 -std=c++17 -arch=sm_86 src/alph_cuda_miner.cu -o alph-cuda-miner
```

On Windows:

```powershell
cd D:\BombTower\alph-cuda-miner
nvcc -O3 -std=c++17 -arch=sm_86 src\alph_cuda_miner.cu -o alph-cuda-miner.exe ws2_32.lib
```

CMake build:

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

Change `sm_86` to your GPU architecture if needed.

## Ubuntu Run

Shared pool example:

```bash
./alph-cuda-miner \
  -o stratum+tcp://us.icminers.com:9160 \
  -u YOUR_WALLET_ADDRESS.worker1 \
  -p x
```

Or use the Ubuntu helper:

```bash
./run-icminers-ubuntu.sh YOUR_WALLET_ADDRESS.worker1
```

Optional environment overrides:

```bash
POOL_URL=stratum+tcp://us.icminers.com:9161 DEVICE=1 ./run-icminers-ubuntu.sh YOUR_WALLET_ADDRESS.worker1
```

Multi-GPU run, one miner process per CUDA device:

```bash
DEVICES=0,1,2,3 ./run-icminers-multigpu-ubuntu.sh YOUR_WALLET_ADDRESS.worker1
tail -f logs/gpu*.log
```

Each GPU gets a distinct worker suffix, for example:

```text
YOUR_WALLET_ADDRESS.worker1.gpu0
YOUR_WALLET_ADDRESS.worker1.gpu1
YOUR_WALLET_ADDRESS.worker1.gpu2
YOUR_WALLET_ADDRESS.worker1.gpu3
```

Windows:

```powershell
.\alph-cuda-miner.exe -o stratum+tcp://us.icminers.com:9160 -u YOUR_WALLET_ADDRESS.worker1 -p x
```

Useful flags:

```text
--device N              CUDA device id, default 0
--batch N               nonces per kernel launch, default 16777216
--threads N             CUDA threads per block, default 256
--blocks N              CUDA block count, default chosen from GPU SM count
--nonce-bytes N         total ALPH nonce field bytes, default 24
--nonce-sans-bytes N    bytes searched/submitted as nonceSansExtraNonce, default 8
--nonce-mode MODE       replace-tail, replace-at, or append; default replace-tail
--nonce-offset N        offset for replace-at mode
--target-order be|le    target/hash comparison byte order, default be
```

The defaults follow the common Alephium pool layout: the pool supplies an
`extraNonce`, the miner searches an 8-byte `nonceSansExtraNonce`, and the full
nonce field is written into the tail of the Stratum header before BLAKE3.

## Status

This is a dedicated, from-scratch miner skeleton with a CUDA BLAKE3 search
kernel and Alephium Stratum client. Before trusting payouts, test with a low
difficulty ALPH pool port and confirm that accepted shares increase on the
pool dashboard. If all shares reject, adjust `--nonce-mode`, `--nonce-offset`,
or `--target-order` to match the pool's exact header packing.

References:

- Alephium mining docs: https://docs.alephium.org/mining/
- Alephium Stratum spec: https://docs.alephium.org/mining/alephium-stratum/
- ICMiners: https://icminers.com/
