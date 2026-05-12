#!/bin/bash
# Laptop A — Experiment 1 publisher 자동 관리
#
# 사용법:
#   ./scripts/run_exp1_pub.sh
#   ./scripts/run_exp1_pub.sh --scenarios S3b,S4b,S5b
#   ./scripts/run_exp1_pub.sh --runs 3
#   ./scripts/run_exp1_pub.sh --sync <Laptop-B-wlan-IP>   # 이벤트 동기화
#
# --sync 없으면 타이머 기반 동기화 (SCENARIO_WAIT).
# --sync 있으면 nc 핸드셰이크:
#   B → A: "DONE" on port 55001  (B가 시나리오 완료 후 통보)
#   A → B: "READY" on port 55002 (A가 publisher 전환 후 통보)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

ALL_SCENARIOS=(S1 S2 S3a S3b S3c S4a S4b S5a S5b)
SCENARIOS=()
N_RUNS=10
BUFFER_S=180   # 타이머 모드 전용 여유 시간 (초)
SYNC_HOST=""   # B의 wlan IP (--sync 로 지정)
SYNC_PORT=55001      # B → A "DONE"
SYNC_ACK_PORT=55002  # A → B "READY"

while [[ $# -gt 0 ]]; do
  case $1 in
    --scenarios) IFS=',' read -ra SCENARIOS <<< "$2"; shift 2 ;;
    --runs)      N_RUNS="$2"; shift 2 ;;
    --buffer)    BUFFER_S="$2"; shift 2 ;;
    --sync)      SYNC_HOST="$2"; shift 2 ;;
    *) echo "[ERROR] unknown option: $1"; exit 1 ;;
  esac
done
[[ ${#SCENARIOS[@]} -eq 0 ]] && SCENARIOS=("${ALL_SCENARIOS[@]}")

set +u
source /opt/ros/humble/setup.bash
source "${REPO_DIR}/install/setup.bash"
set -u
export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-77}

# 타이머 모드: 시나리오당 Laptop B 소요 시간
SECS_PER_RUN=80   # 70s subscriber + 10s sleep
SCENARIO_WAIT=$(( 5 * N_RUNS * SECS_PER_RUN + BUFFER_S ))
TOTAL_SECS=$(( ${#SCENARIOS[@]} * SCENARIO_WAIT ))
TOTAL_H=$(( TOTAL_SECS / 3600 ))
TOTAL_M=$(( (TOTAL_SECS % 3600) / 60 ))

echo "════════════════════════════════════════════════"
echo " Experiment 1 — Laptop A (Publisher)"
echo " 시나리오  : ${SCENARIOS[*]}"
echo " 반복      : ${N_RUNS}회"
if [[ -n "${SYNC_HOST}" ]]; then
  echo " 동기화    : 이벤트 기반 (B=${SYNC_HOST})"
else
  echo " 동기화    : 타이머 기반 (${SCENARIO_WAIT}s/시나리오)"
  echo " 예상시간  : ${TOTAL_H}h ${TOTAL_M}m"
fi
echo "════════════════════════════════════════════════"
echo ""
echo " Laptop B에서 run_exp1_sub.sh 를 실행하고"
echo " 양쪽 동시에 Enter를 눌러 시작하세요."
echo " 이후 자동으로 실행됩니다."
echo ""
read -rp "준비 완료 후 Enter..."

# ── 동기화 함수 ──────────────────────────────────────────────────────────────

# B의 "DONE" 신호 수신 (B가 시나리오 완료 후 전송)
wait_done_from_b() {
  echo "  [sync] B의 DONE 신호 대기 중... (port ${SYNC_PORT})"
  nc -l -p "${SYNC_PORT}" > /dev/null 2>&1 || true
  echo "  [sync] DONE 수신  $(date '+%H:%M:%S')"
}

# B에 "READY" 신호 전송 (publisher 전환 완료 후)
send_ready_to_b() {
  local attempt
  for attempt in 1 2 3; do
    if echo "READY" | nc -w5 "${SYNC_HOST}" "${SYNC_ACK_PORT}" 2>/dev/null; then
      echo "  [sync] READY 전송 완료  $(date '+%H:%M:%S')"
      return 0
    fi
    echo "  [sync] READY 전송 실패 (attempt ${attempt}/3), 재시도..."
    sleep 2
  done
  echo "  [sync][WARN] READY 전송 실패 — B가 자체 타임아웃으로 진행"
}

# ── Publisher 제어 ────────────────────────────────────────────────────────────

PUB_PID=""

stop_current() {
  if [[ -n "${PUB_PID}" ]]; then
    echo "[pub] 종료 (PID ${PUB_PID})  $(date '+%H:%M:%S')"
    kill "${PUB_PID}" 2>/dev/null || true
    wait "${PUB_PID}" 2>/dev/null || true
    # pub_a.sh가 SIGTERM으로 종료될 때 cleanup trap이 실행 안 될 수 있으므로 직접 정리
    pkill -f "ros2 run test .*pub" 2>/dev/null || true
    pkill -f "ros2 launch test .*pub" 2>/dev/null || true
    sleep 1
    PUB_PID=""
  fi
}
trap stop_current EXIT

# ── 메인 루프 ─────────────────────────────────────────────────────────────────

for SCENARIO in "${SCENARIOS[@]}"; do
  echo ""
  echo "════════════════════════════════════════════"
  echo " [$(date '+%H:%M:%S')] 시나리오: ${SCENARIO}"
  echo "════════════════════════════════════════════"

  bash "${SCRIPT_DIR}/pub_a.sh" "${SCENARIO}" &
  PUB_PID=$!
  echo "[pub] 시작 (PID ${PUB_PID})"

  if [[ -n "${SYNC_HOST}" ]]; then
    # 이벤트 기반: B의 완료 신호를 기다림
    wait_done_from_b
  else
    # 타이머 기반: SCENARIO_WAIT 동안 대기
    END_TS=$(( $(date +%s) + SCENARIO_WAIT ))
    while (( $(date +%s) < END_TS )); do
      REMAINING=$(( END_TS - $(date +%s) ))
      printf "\r  대기 중... %4ds 남음 " "${REMAINING}"
      sleep 5
    done
    echo ""
  fi

  stop_current
  echo "[pub] ${SCENARIO} 완료  $(date '+%H:%M:%S')"

  # publisher 전환 후 B에 통보 (마지막 시나리오 제외)
  if [[ -n "${SYNC_HOST}" && "${SCENARIO}" != "${SCENARIOS[-1]}" ]]; then
    send_ready_to_b
  fi
done

echo ""
echo "════════════════════════════════════════════════"
echo " Experiment 1 (Laptop A) 완료  $(date '+%H:%M:%S')"
echo "════════════════════════════════════════════════"
