#!/bin/bash
# Laptop A — Experiment 1 publisher 관리
#
# 사용법:
#   ./scripts/run_exp1_a.sh
#   ./scripts/run_exp1_a.sh --scenarios S3b,S4b,S5b
#
# Laptop B의 run_exp1.sh 와 시나리오 순서가 동일하다.
# 양쪽 모두 시나리오 전환 시 Enter 대기 → 사람이 동기화.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

ALL_SCENARIOS=(S1 S2 S3a S3b S3c S4a S4b S5a S5b)
SCENARIOS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --scenarios) IFS=',' read -ra SCENARIOS <<< "$2"; shift 2 ;;
    *) echo "[ERROR] unknown option: $1"; exit 1 ;;
  esac
done
[[ ${#SCENARIOS[@]} -eq 0 ]] && SCENARIOS=("${ALL_SCENARIOS[@]}")

source /opt/ros/humble/setup.bash
source "${REPO_DIR}/install/setup.bash"
export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-77}

echo "════════════════════════════════════════════════"
echo " Experiment 1 — Laptop A (Publisher)"
echo " 시나리오: ${SCENARIOS[*]}"
echo "════════════════════════════════════════════════"
echo ""
echo " Laptop B에서 run_exp1.sh 를 먼저 실행하고"
echo " 양쪽 동시에 Enter를 눌러 시작하세요."
echo ""
read -rp "준비 완료 후 Enter..."

PUB_PID=""

stop_current() {
  if [[ -n "${PUB_PID}" ]]; then
    echo "[pub] 종료 (PID ${PUB_PID})"
    kill "${PUB_PID}" 2>/dev/null || true
    wait "${PUB_PID}" 2>/dev/null || true
    PUB_PID=""
  fi
}
trap stop_current EXIT

for SCENARIO in "${SCENARIOS[@]}"; do
  echo ""
  echo "════════════════════════════════════════════════"
  echo " 시나리오: ${SCENARIO}  ($(date '+%H:%M:%S'))"
  echo "════════════════════════════════════════════════"

  # publisher 백그라운드 실행
  bash "${SCRIPT_DIR}/pub_a.sh" "${SCENARIO}" &
  PUB_PID=$!
  echo "[pub] 시작 (PID ${PUB_PID})"

  # Laptop B 측 완료 대기
  echo ""
  echo " Laptop B의 ${SCENARIO} 완료 후 Enter..."
  read -rp ""

  stop_current
  echo " ✓ ${SCENARIO} publisher 종료"
done

echo ""
echo "════════════════════════════════════════════════"
echo " Experiment 1 (Laptop A) 완료"
echo "════════════════════════════════════════════════"
