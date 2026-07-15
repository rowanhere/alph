CUDA_ARCH ?= sm_86
CXXSTD ?= c++17
NVCC ?= nvcc
TARGET ?= alph-cuda-miner

NVCCFLAGS ?= -O3 -std=$(CXXSTD) -arch=$(CUDA_ARCH)

.PHONY: all clean

all: $(TARGET)

$(TARGET): src/alph_cuda_miner.cu
	$(NVCC) $(NVCCFLAGS) $< -o $@

clean:
	rm -f $(TARGET)

