#!/usr/bin/env bash
set -euo pipefail

BASE_USER="${1:-${ALPH_USER:-}}"
POOL_URL="${POOL_URL:-stratum+tcp://us.icminers.com:9160}"
PASSWORD="${PASSWORD:-x}"
DEVICES="${DEVICES:-0,1,2,3}"
REFRESH="${REFRESH:-2}"

if [[ -z "$BASE_USER" ]]; then
  echo "Usage: DEVICES=0,1,2,3 ./run-srb-dashboard-ubuntu.sh YOUR_WALLET_ADDRESS.worker1" >&2
  echo "Or set ALPH_USER=YOUR_WALLET_ADDRESS.worker1" >&2
  exit 2
fi

if [[ ! -x ./alph-cuda-miner ]]; then
  echo "./alph-cuda-miner not found or not executable. Run ./build-ubuntu.sh first." >&2
  exit 1
fi

mkdir -p logs
rm -f logs/gpu*.log

pids=()
devices=()
started_at="$(date +%s)"

cleanup() {
  for pid in "${pids[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  wait >/dev/null 2>&1 || true
  tput cnorm >/dev/null 2>&1 || true
}
trap cleanup INT TERM EXIT

IFS=',' read -ra ids <<< "$DEVICES"
for raw_id in "${ids[@]}"; do
  device="$(echo "$raw_id" | xargs)"
  [[ -z "$device" ]] && continue
  devices+=("$device")

  user="${BASE_USER}.gpu${device}"
  log="logs/gpu${device}.log"
  ./alph-cuda-miner \
    -o "$POOL_URL" \
    -u "$user" \
    -p "$PASSWORD" \
    --device "$device" >"$log" 2>&1 &
  pids+=("$!")
done

format_uptime() {
  local now elapsed h m s
  now="$(date +%s)"
  elapsed=$((now - started_at))
  h=$((elapsed / 3600))
  m=$(((elapsed % 3600) / 60))
  s=$((elapsed % 60))
  printf "%02d:%02d:%02d" "$h" "$m" "$s"
}

field_or_dash() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf -- "-"
  else
    printf "%s" "$value"
  fi
}

render_gpu() {
  local device="$1"
  local log="logs/gpu${device}.log"
  local current avg job shares last_share status rejects accepts

  current="-"
  avg="-"
  job="-"
  shares="0"
  accepts="0"
  rejects="0"
  last_share="-"
  status="starting"

  if [[ -f "$log" ]]; then
    local miner_line
    miner_line="$(grep -a '\[MINER\]' "$log" | tail -n 1 || true)"
    if [[ -n "$miner_line" ]]; then
      current="$(echo "$miner_line" | sed -n 's/.*\[MINER\] \([0-9.]* MH\/s\) current.*/\1/p')"
      avg="$(echo "$miner_line" | sed -n 's/.*current, \([0-9.]* MH\/s\) avg.*/\1/p')"
      job="$(echo "$miner_line" | sed -n 's/.*job=\([^ ]*\).*/\1/p')"
      status="mining"
    fi

    shares="$(grep -a -c '\[SHARE\] submitted' "$log" || true)"
    local share_line
    share_line="$(grep -a '\[SHARE\] submitted' "$log" | tail -n 1 || true)"
    if [[ -n "$share_line" ]]; then
      last_share="$(echo "$share_line" | sed -n 's/.*nonceSansExtraNonce=\([^ ]*\).*/\1/p')"
    fi

    accepts="$(grep -a '\[SUBMIT\]' "$log" | grep -a -ci 'result.*true\|accepted' || true)"
    rejects="$(grep -a '\[SUBMIT\]' "$log" | grep -a -ci 'result.*false\|reject\|invalid\|stale' || true)"

    if grep -a -q '\[ERROR\]' "$log"; then
      status="error"
    fi
  fi

  printf "%-4s %-10s %-12s %-12s %-8s %-8s %-8s %-18s\n" \
    "$device" "$status" \
    "$(field_or_dash "$current")" \
    "$(field_or_dash "$avg")" \
    "$(field_or_dash "$shares")" \
    "$(field_or_dash "$accepts")" \
    "$(field_or_dash "$rejects")" \
    "$(field_or_dash "$job")"
}

tput civis >/dev/null 2>&1 || true
while true; do
  clear
  echo "ALPH CUDA MINER - SRB STYLE DASHBOARD"
  echo "Pool: ${POOL_URL}"
  echo "User: ${BASE_USER}.*"
  echo "Devices: ${DEVICES}    Uptime: $(format_uptime)    Refresh: ${REFRESH}s"
  echo "=========================================================================="
  printf "%-4s %-10s %-12s %-12s %-8s %-8s %-8s %-18s\n" \
    "GPU" "STATUS" "CURRENT" "AVERAGE" "SHARES" "ACCEPT" "REJECT" "JOB"
  echo "--------------------------------------------------------------------------"
  for device in "${devices[@]}"; do
    render_gpu "$device"
  done
  echo "=========================================================================="
  echo "Ctrl+C to stop all GPUs. Logs: logs/gpuN.log"
  sleep "$REFRESH"
done
