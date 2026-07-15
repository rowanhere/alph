#!/usr/bin/env bash
set -euo pipefail

CUDA_ARCH="${CUDA_ARCH:-sm_86}"

if ! command -v nvcc >/dev/null 2>&1; then
  echo "nvcc not found. Install the NVIDIA CUDA toolkit first." >&2
  echo "Ubuntu example: sudo apt install nvidia-cuda-toolkit" >&2
  exit 1
fi

make CUDA_ARCH="$CUDA_ARCH"

