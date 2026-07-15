#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ALPH_USER="3cUq7e2scUmfZYsPTndakWSmjihxTWrEqjD7isyRTQK1AjtKNMpGY.worker1"
BASE_USER="${1:-${ALPH_USER:-$DEFAULT_ALPH_USER}}"
POOL_URL="${POOL_URL:-stratum+tcp://us.icminers.com:9160}"
PASSWORD="${PASSWORD:-x}"
DEVICES="${DEVICES:-0,1,2,3}"

if [[ -z "$BASE_USER" ]]; then
  echo "Usage: DEVICES=0,1,2,3 ./run-icminers-multigpu-ubuntu.sh WALLET.worker" >&2
  echo "Or set ALPH_USER=WALLET.worker" >&2
  exit 2
fi

if [[ ! -x ./alph-cuda-miner ]]; then
  echo "./alph-cuda-miner not found or not executable. Run ./build-ubuntu.sh first." >&2
  exit 1
fi

mkdir -p logs

pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  wait >/dev/null 2>&1 || true
}
trap cleanup INT TERM EXIT

IFS=',' read -ra ids <<< "$DEVICES"
for raw_id in "${ids[@]}"; do
  device="$(echo "$raw_id" | xargs)"
  [[ -z "$device" ]] && continue

  user="$BASE_USER"
  if [[ "$BASE_USER" == *.* ]]; then
    user="${BASE_USER}.gpu${device}"
  else
    user="${BASE_USER}.gpu${device}"
  fi

  log="logs/gpu${device}.log"
  echo "[LAUNCH] GPU ${device} -> ${user} (${log})"
  ./alph-cuda-miner \
    -o "$POOL_URL" \
    -u "$user" \
    -p "$PASSWORD" \
    --device "$device" >"$log" 2>&1 &
  pids+=("$!")
done

echo "[LAUNCH] Started ${#pids[@]} miner process(es)."
echo "[LAUNCH] Watch logs with: tail -f logs/gpu*.log"
wait
