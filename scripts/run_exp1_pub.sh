#!/bin/bash
# Laptop A — Experiment 1 publisher 자동 관리
#
# 사용법:
#   ./scripts/run_exp1_a.sh
#   ./scripts/run_exp1_a.sh --scenarios S3b,S4b,S5b
#   ./scripts/run_exp1_a.sh --runs 3
#
# Laptop B의 run_exp1.sh 와 시작 시 Enter 한 번만 동기화.
# 이후 타이머 기반으로 완전 자동 실행.
#
# 타이밍: 시나리오당 대기 = 5조건 × runs × 80s + BUFFER_S

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

ALL_SCENARIOS=(S1 S2 S3a S3b S3c S4a S4b S5a S5b)
SCENARIOS=()
N_RUNS=10
BUFFER_S=180   # 시나리오당 여유 시간 (초)

while [[ $# -gt 0 ]]; do
  case $1 in
    --scenarios) IFS=',' read -ra SCENARIOS <<< "$2"; shift 2 ;;
    --runs)      N_RUNS="$2"; shift 2 ;;
    --buffer)    BUFFER_S="$2"; shift 2 ;;
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

# 시나리오당 Laptop B 소요 시간
SECS_PER_RUN=80   # 70s subscriber + 10s sleep
SCENARIO_WAIT=$(( 5 * N_RUNS * SECS_PER_RUN + BUFFER_S ))
TOTAL_SECS=$(( ${#SCENARIOS[@]} * SCENARIO_WAIT ))
TOTAL_H=$(( TOTAL_SECS / 3600 ))
TOTAL_M=$(( (TOTAL_SECS % 3600) / 60 ))

echo "════════════════════════════════════════════════"
echo " Experiment 1 — Laptop A (Publisher)"
echo " 시나리오  : ${SCENARIOS[*]}"
echo " 반복      : ${N_RUNS}회"
echo " 시나리오당: ${SCENARIO_WAIT}s (= 5×${N_RUNS}×80 + ${BUFFER_S}s buffer)"
echo " 예상시간  : ${TOTAL_H}h ${TOTAL_M}m"
echo "════════════════════════════════════════════════"
echo ""
echo " Laptop B에서 run_exp1.sh 를 실행하고"
echo " 양쪽 동시에 Enter를 눌러 시작하세요."
echo " 이후 자동으로 실행됩니다."
echo ""
read -rp "준비 완료 후 Enter..."

PUB_PID=""

stop_current() {
  if [[ -n "${PUB_PID}" ]]; then
    echo "[pub] 종료 (PID ${PUB_PID})  $(date '+%H:%M:%S')"
    kill "${PUB_PID}" 2>/dev/null || true
    wait "${PUB_PID}" 2>/dev/null || true
    PUB_PID=""
  fi
}
trap stop_current EXIT

for SCENARIO in "${SCENARIOS[@]}"; do
  echo ""
  echo "════════════════════════════════════════════"
  echo " [$(date '+%H:%M:%S')] 시나리오: ${SCENARIO}"
  echo "════════════════════════════════════════════"

  bash "${SCRIPT_DIR}/pub_a.sh" "${SCENARIO}" &
  PUB_PID=$!
  echo "[pub] 시작 (PID ${PUB_PID})"

  # Laptop B의 해당 시나리오 완료까지 대기
  END_TS=$(( $(date +%s) + SCENARIO_WAIT ))
  while (( $(date +%s) < END_TS )); do
    REMAINING=$(( END_TS - $(date +%s) ))
    printf "\r  대기 중... %4ds 남음 " "${REMAINING}"
    sleep 5
  done
  echo ""

  stop_current
  echo "[pub] ${SCENARIO} 완료  $(date '+%H:%M:%S')"
done

echo ""
echo "════════════════════════════════════════════════"
echo " Experiment 1 (Laptop A) 완료  $(date '+%H:%M:%S')"
echo "════════════════════════════════════════════════"
