#!/bin/bash
# Laptop B — Experiment 1 전체 자동 실행
#
# 사용법:
#   ./scripts/run_exp1_sub.sh --sync <Laptop-A-wlan-IP>   # 이벤트 기반 (권장)
#   ./scripts/run_exp1_sub.sh                             # 타이머 기반 (레거시)
#
# 이벤트 기반: run마다 A에 START/STOP 전송 → pub 생명주기 정밀 제어
# 타이머 기반: SCENARIO_WAIT 동안 대기 (--sync 없을 때)
#
# 주의: --sync 통신은 WiFi(wlan0) 경유 — eth0 ΔRX 오염 없음

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

ALL_SCENARIOS=(S1 S2 S3a S3b S3c S4a S4b S5a S5b)
SCENARIOS=()
N_RUNS=10
BUFFER_S=180
SYNC_HOST=""
SYNC_PORT=55001
SYNC_ACK_PORT=55002

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
if ! command -v ros2 &>/dev/null; then
  source /opt/ros/humble/setup.bash
fi
source "${REPO_DIR}/install/setup.bash"
set -u
export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-77}

NIC=${NIC:-$(ip route show default | awk '/default/ {print $5; exit}')}
export NIC
export SYNC_HOST
export SYNC_PORT
export SYNC_ACK_PORT

# 시간 추정 (run당 ~84s: 2s pub ready + 10s warmup + 60s measure + 2s stop + 10s sleep)
SECS_PER_RUN=84
TOTAL_SECS=$(( ${#SCENARIOS[@]} * 5 * N_RUNS * SECS_PER_RUN ))
TOTAL_H=$(( TOTAL_SECS / 3600 ))
TOTAL_M=$(( (TOTAL_SECS % 3600) / 60 ))

echo "════════════════════════════════════════════════"
echo " Experiment 1 — Laptop B (Subscriber)"
echo " 시나리오 : ${SCENARIOS[*]}"
echo " 조건     : baseline rp_hz rp_bag topic_hz rosbag2"
echo " 반복     : ${N_RUNS}회"
echo " NIC      : ${NIC}"
if [[ -n "${SYNC_HOST}" ]]; then
  echo " 동기화   : 이벤트 기반 (A=${SYNC_HOST}, run별 pub 시작/종료)"
else
  echo " 동기화   : 타이머 기반"
  echo " 예상시간 : ${TOTAL_H}h ${TOTAL_M}m"
fi
echo "════════════════════════════════════════════════"
echo ""
echo "사전 확인:"
echo "  1) PTP 동기화 offset < ±1μs"
echo "  2) Laptop A에서 run_exp1_pub.sh 실행 후 대기 중"
echo ""
read -rp "준비 완료 후 Enter (Laptop A와 동시에)..."

START_TIME=$(date +%s)
FAILED=()
# rp 조건을 먼저 실행해 ros2 tool의 DDS 잔재 오염 방지
CONDITIONS=(baseline rp_hz rp_bag topic_hz rosbag2)

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

  # 타이머 모드: 마지막 시나리오가 아니면 남은 시간 대기
  if [[ -z "${SYNC_HOST}" && "${SCENARIO}" != "${SCENARIOS[-1]}" ]]; then
    SECS_PER_RUN_TIMER=80
    SCENARIO_WAIT=$(( 5 * N_RUNS * SECS_PER_RUN_TIMER + BUFFER_S ))
    REMAINING=$(( SCENARIO_WAIT - ELAPSED ))
    if (( REMAINING > 0 )); then
      echo "  다음 시나리오까지 ${REMAINING}s 대기..."
      sleep "${REMAINING}"
    fi
  fi
done

# 이벤트 모드: A에 실험 완료 통보
if [[ -n "${SYNC_HOST}" ]]; then
  echo "DONE" | nc -w5 "${SYNC_HOST}" "${SYNC_PORT}" 2>/dev/null || true
  echo "  [sync] DONE 전송 완료"
fi

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
