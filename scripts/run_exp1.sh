#!/bin/bash
# Experiment 1 전체 실행 (Laptop B)
#
# 사용법:
#   수동 모드 (기본):
#     ./scripts/run_exp1.sh
#     ./scripts/run_exp1.sh --scenarios S3b,S4b,S5b
#     ./scripts/run_exp1.sh --runs 3
#
#   SSH 자동 모드 (Laptop A publisher 자동 제어):
#     ./scripts/run_exp1.sh --ssh user@192.168.1.10
#     ./scripts/run_exp1.sh --ssh user@192.168.1.10 --scenarios S3b,S5b --runs 3
#
# 환경변수:
#   LAPTOP_A_REPO   Laptop A의 rp-exp 경로 (기본: ~/rp-exp)
#   NIC             네트워크 인터페이스 (기본: 자동 감지)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

# ── 기본값 ──────────────────────────────────────────────────────────────────
ALL_SCENARIOS=(S1 S2 S3a S3b S3c S4a S4b S5a S5b)
SCENARIOS=()
N_RUNS=10
SSH_TARGET=""
LAPTOP_A_REPO="${LAPTOP_A_REPO:-~/rp-exp}"

# ── 인수 파싱 ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --scenarios)
      IFS=',' read -ra SCENARIOS <<< "$2"; shift 2 ;;
    --runs)
      N_RUNS="$2"; shift 2 ;;
    --ssh)
      SSH_TARGET="$2"; shift 2 ;;
    *)
      echo "[ERROR] unknown option: $1"; exit 1 ;;
  esac
done

[[ ${#SCENARIOS[@]} -eq 0 ]] && SCENARIOS=("${ALL_SCENARIOS[@]}")

# ── 시간 추정 ────────────────────────────────────────────────────────────────
N_SCENARIOS=${#SCENARIOS[@]}
SECS_PER_RUN=80          # 70s sub + 10s sleep
SECS_PER_SCENARIO=$((5 * N_RUNS * SECS_PER_RUN))
TOTAL_SECS=$((N_SCENARIOS * SECS_PER_SCENARIO))
TOTAL_H=$((TOTAL_SECS / 3600))
TOTAL_M=$(( (TOTAL_SECS % 3600) / 60 ))

# ── publisher 제어 함수 ──────────────────────────────────────────────────────
PUB_SSH_PID=""

start_publisher() {
  local scenario=$1
  if [[ -n "${SSH_TARGET}" ]]; then
    echo "[pub] SSH: ${SSH_TARGET} → pub_a.sh ${scenario}"
    ssh "${SSH_TARGET}" \
      "source /opt/ros/humble/setup.bash && \
       source ${LAPTOP_A_REPO}/install/setup.bash && \
       export RMW_IMPLEMENTATION=rmw_fastrtps_cpp && \
       export ROS_DOMAIN_ID=77 && \
       ${LAPTOP_A_REPO}/scripts/pub_a.sh ${scenario}" &
    PUB_SSH_PID=$!
    sleep 3  # publisher 기동 대기
  else
    echo ""
    echo "┌─────────────────────────────────────────────┐"
    echo "│  [Laptop A] 아래 명령어를 실행하세요:        │"
    echo "│                                              │"
    echo "│  ./scripts/pub_a.sh ${scenario}$(printf '%*s' $((14 - ${#scenario})) '')│"
    echo "│                                              │"
    echo "└─────────────────────────────────────────────┘"
    read -rp "  publisher 실행 후 Enter..."
  fi
}

stop_publisher() {
  local scenario=$1
  if [[ -n "${SSH_TARGET}" && -n "${PUB_SSH_PID}" ]]; then
    echo "[pub] 종료: ${scenario}"
    # SSH 세션의 원격 프로세스 그룹 종료
    ssh "${SSH_TARGET}" \
      "pkill -f 'pub_a.sh ${scenario}' 2>/dev/null; \
       pkill -f 'ros2 run test.*pub' 2>/dev/null; \
       pkill -f 'ros2 launch test.*pub' 2>/dev/null; \
       true" || true
    kill "${PUB_SSH_PID}" 2>/dev/null || true
    wait "${PUB_SSH_PID}" 2>/dev/null || true
    PUB_SSH_PID=""
  else
    echo ""
    echo "  [Laptop A] publisher 종료하세요 (Ctrl-C)"
    read -rp "  종료 확인 후 Enter..."
  fi
}

# ── 시작 안내 ────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════"
echo " Experiment 1"
echo " 시나리오 : ${SCENARIOS[*]}"
echo " 조건     : baseline topic_hz rosbag2 rp_hz rp_bag"
echo " 반복     : ${N_RUNS}회"
echo " 예상시간 : ${TOTAL_H}h ${TOTAL_M}m"
echo " 모드     : ${SSH_TARGET:-수동}"
if [[ -n "${SSH_TARGET}" ]]; then
  echo " Laptop A : ${SSH_TARGET}"
fi
echo "════════════════════════════════════════════════"
echo ""
echo "사전 확인:"
echo "  1) PTP 동기화 offset < ±1μs"
echo "  2) RMW_IMPLEMENTATION=rmw_fastrtps_cpp"
echo "  3) ROS_DOMAIN_ID=77"
echo ""
read -rp "준비 완료 후 Enter..."

START_TIME=$(date +%s)
FAILED=()

# ── 시나리오 루프 ────────────────────────────────────────────────────────────
for SCENARIO in "${SCENARIOS[@]}"; do
  SCENARIO_START=$(date +%s)
  echo ""
  echo "════════════════════════════════════════════════"
  echo " 시나리오: ${SCENARIO}  ($(date '+%H:%M:%S'))"
  echo "════════════════════════════════════════════════"

  start_publisher "${SCENARIO}"

  CONDITIONS=(baseline topic_hz rosbag2 rp_hz rp_bag)
  for CONDITION in "${CONDITIONS[@]}"; do
    echo ""
    echo "  ── ${SCENARIO} / ${CONDITION} ──────────────────"
    for i in $(seq 1 "${N_RUNS}"); do
      RUN_LABEL="$(printf '%02d' ${i})/${N_RUNS}"
      echo "    run ${RUN_LABEL}  ($(date '+%H:%M:%S'))"
      if ! bash "${SCRIPT_DIR}/run_b.sh" "${SCENARIO}" "${CONDITION}" "${i}"; then
        echo "    [WARN] run ${RUN_LABEL} failed, continuing"
        FAILED+=("${SCENARIO}/${CONDITION}/run$(printf '%02d' ${i})")
      fi
    done
    echo "  ✓ ${CONDITION} 완료"
  done

  stop_publisher "${SCENARIO}"

  SCENARIO_END=$(date +%s)
  ELAPSED=$(( SCENARIO_END - SCENARIO_START ))
  echo ""
  echo "  ✓ ${SCENARIO} 완료 — ${ELAPSED}s"
done

# ── 최종 요약 ────────────────────────────────────────────────────────────────
END_TIME=$(date +%s)
TOTAL_ELAPSED=$(( END_TIME - START_TIME ))
TOTAL_H_ACT=$(( TOTAL_ELAPSED / 3600 ))
TOTAL_M_ACT=$(( (TOTAL_ELAPSED % 3600) / 60 ))

echo ""
echo "════════════════════════════════════════════════"
echo " Experiment 1 완료"
echo " 총 소요 : ${TOTAL_H_ACT}h ${TOTAL_M_ACT}m"
echo " 결과    : ${REPO_DIR}/results/exp1/"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo " 실패 run:"
  for f in "${FAILED[@]}"; do echo "   - ${f}"; done
fi
echo "════════════════════════════════════════════════"
