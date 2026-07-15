#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ALPH_USER="3cUq7e2scUmfZYsPTndakWSmjihxTWrEqjD7isyRTQK1AjtKNMpGY.worker1"
WALLET_WORKER="${1:-${ALPH_USER:-$DEFAULT_ALPH_USER}}"
POOL_URL="${POOL_URL:-stratum+tcp://us.icminers.com:9160}"
PASSWORD="${PASSWORD:-x}"
DEVICE="${DEVICE:-0}"

if [[ -z "$WALLET_WORKER" ]]; then
  echo "Usage: ./run-icminers-ubuntu.sh WALLET.worker" >&2
  echo "Or set ALPH_USER=WALLET.worker" >&2
  exit 2
fi

exec ./alph-cuda-miner \
  -o "$POOL_URL" \
  -u "$WALLET_WORKER" \
  -p "$PASSWORD" \
  --device "$DEVICE"
