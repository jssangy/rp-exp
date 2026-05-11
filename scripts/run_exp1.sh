#!/bin/bash
# Laptop B — Experiment 1 전체 자동 실행
#
# 사용법:
#   ./scripts/run_exp1.sh
#   ./scripts/run_exp1.sh --scenarios S3b,S4b,S5b
#   ./scripts/run_exp1.sh --scenarios S1 --runs 3   # 테스트
#
# Laptop A에서 run_exp1_a.sh 를 동시에 실행한다.
# 시작 시 Enter 한 번 맞추면 이후 완전 자동 실행.
#
# 주의: SSH를 통한 원격 publisher 제어는 eth0 ΔRX 측정을 오염시키므로
#       별도 관리 NIC(WiFi 등)이 없는 한 사용하지 않는다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

ALL_SCENARIOS=(S1 S2 S3a S3b S3c S4a S4b S5a S5b)
SCENARIOS=()
N_RUNS=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --scenarios) IFS=',' read -ra SCENARIOS <<< "$2"; shift 2 ;;
    --runs)      N_RUNS="$2"; shift 2 ;;
    *) echo "[ERROR] unknown option: $1"; exit 1 ;;
  esac
done
[[ ${#SCENARIOS[@]} -eq 0 ]] && SCENARIOS=("${ALL_SCENARIOS[@]}")

# ROS 환경
if ! command -v ros2 &>/dev/null; then
  source /opt/ros/humble/setup.bash
fi
source "${REPO_DIR}/install/setup.bash"
export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-77}

# NIC 자동 감지
NIC=${NIC:-$(ip route show default | awk '/default/ {print $5; exit}')}
export NIC

# 시간 추정
TOTAL_SECS=$(( ${#SCENARIOS[@]} * 5 * N_RUNS * 80 ))
TOTAL_H=$(( TOTAL_SECS / 3600 ))
TOTAL_M=$(( (TOTAL_SECS % 3600) / 60 ))

echo "════════════════════════════════════════════════"
echo " Experiment 1 — Laptop B (Subscriber)"
echo " 시나리오 : ${SCENARIOS[*]}"
echo " 조건     : baseline topic_hz rosbag2 rp_hz rp_bag"
echo " 반복     : ${N_RUNS}회"
echo " NIC      : ${NIC}"
echo " 예상시간 : ${TOTAL_H}h ${TOTAL_M}m"
echo "════════════════════════════════════════════════"
echo ""
echo "사전 확인:"
echo "  1) PTP 동기화 offset < ±1μs"
echo "  2) Laptop A에서 run_exp1_a.sh 실행 후 대기 중"
echo ""
read -rp "준비 완료 후 Enter (Laptop A와 동시에)..."

START_TIME=$(date +%s)
FAILED=()
CONDITIONS=(baseline topic_hz rosbag2 rp_hz rp_bag)

for SCENARIO in "${SCENARIOS[@]}"; do
  SCENARIO_START=$(date +%s)
  echo ""
  echo "════════════════════════════════════════════════"
  echo " [$(date '+%H:%M:%S')] 시나리오: ${SCENARIO}"
  echo "════════════════════════════════════════════════"

  for CONDITION in "${CONDITIONS[@]}"; do
    echo ""
    echo "  ── ${SCENARIO} / ${CONDITION} ──────────────────"
    for i in $(seq 1 "${N_RUNS}"); do
      RUN_LABEL="$(printf '%02d' ${i})/${N_RUNS}"
      echo "    run ${RUN_LABEL}  ($(date '+%H:%M:%S'))"
      if ! bash "${SCRIPT_DIR}/run_b.sh" "${SCENARIO}" "${CONDITION}" "${i}"; then
        echo "    [WARN] run ${RUN_LABEL} 실패, 계속 진행"
        FAILED+=("${SCENARIO}/${CONDITION}/run$(printf '%02d' ${i})")
      fi
    done
    echo "  ✓ ${CONDITION} 완료"
  done

  ELAPSED=$(( $(date +%s) - SCENARIO_START ))
  echo ""
  echo "  ✓ ${SCENARIO} 완료 — ${ELAPSED}s  ($(date '+%H:%M:%S'))"
done

# 최종 요약
TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))
echo ""
echo "════════════════════════════════════════════════"
echo " Experiment 1 완료  $(date '+%H:%M:%S')"
echo " 총 소요 : $(( TOTAL_ELAPSED/3600 ))h $(( (TOTAL_ELAPSED%3600)/60 ))m"
echo " 결과    : ${REPO_DIR}/results/exp1/"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo " 실패 run (재실행 필요):"
  for f in "${FAILED[@]}"; do echo "   - ${f}"; done
fi
echo "════════════════════════════════════════════════"
