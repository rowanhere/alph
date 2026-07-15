#!/usr/bin/env bash
set -euo pipefail

WALLET_WORKER="${1:-${ALPH_USER:-}}"
POOL_URL="${POOL_URL:-stratum+tcp://us.icminers.com:9160}"
PASSWORD="${PASSWORD:-x}"
DEVICE="${DEVICE:-0}"

if [[ -z "$WALLET_WORKER" ]]; then
  echo "Usage: ./run-icminers-ubuntu.sh YOUR_WALLET_ADDRESS.worker1" >&2
  echo "Or set ALPH_USER=YOUR_WALLET_ADDRESS.worker1" >&2
  exit 2
fi

exec ./alph-cuda-miner \
  -o "$POOL_URL" \
  -u "$WALLET_WORKER" \
  -p "$PASSWORD" \
  --device "$DEVICE"

