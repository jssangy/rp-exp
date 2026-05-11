#!/bin/bash
# Laptop B — Experiment 1 전체 자동 실행
#
# 사용법:
#   ./scripts/run_exp1_sub.sh
#   ./scripts/run_exp1_sub.sh --scenarios S3b,S4b,S5b
#   ./scripts/run_exp1_sub.sh --scenarios S1 --runs 3
#   ./scripts/run_exp1_sub.sh --sync <Laptop-A-wlan-IP>   # 이벤트 동기화
#
# --sync 없으면 타이머 기반 동기화 (SCENARIO_WAIT).
# --sync 있으면 nc 핸드셰이크:
#   B → A: "DONE" on port 55001  (시나리오 완료 후 통보)
#   A → B: "READY" on port 55002 (publisher 전환 완료 신호)
#
# 주의: --sync 통신은 WiFi(wlan0) 경유 — eth0 ΔRX 오염 없음.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

ALL_SCENARIOS=(S1 S2 S3a S3b S3c S4a S4b S5a S5b)
SCENARIOS=()
N_RUNS=10
BUFFER_S=180  # 타이머 모드 전용 여유 시간 (초)
SYNC_HOST=""  # A의 wlan IP (--sync 로 지정)
SYNC_PORT=55001      # B → A "DONE"
SYNC_ACK_PORT=55002  # A → B "READY"
SYNC_TIMEOUT=600     # READY 대기 최대 시간 (초)

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

# ROS 환경
set +u
if ! command -v ros2 &>/dev/null; then
  source /opt/ros/humble/setup.bash
fi
source "${REPO_DIR}/install/setup.bash"
set -u
export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-77}

# NIC 자동 감지
NIC=${NIC:-$(ip route show default | awk '/default/ {print $5; exit}')}
export NIC

# 타이머 모드: 시나리오당 대기 시간
SECS_PER_RUN=80
SCENARIO_WAIT=$(( 5 * N_RUNS * SECS_PER_RUN + BUFFER_S ))

# 시간 추정
TOTAL_SECS=$(( ${#SCENARIOS[@]} * SCENARIO_WAIT ))
TOTAL_H=$(( TOTAL_SECS / 3600 ))
TOTAL_M=$(( (TOTAL_SECS % 3600) / 60 ))

echo "════════════════════════════════════════════════"
echo " Experiment 1 — Laptop B (Subscriber)"
echo " 시나리오 : ${SCENARIOS[*]}"
echo " 조건     : baseline topic_hz rosbag2 rp_hz rp_bag"
echo " 반복     : ${N_RUNS}회"
echo " NIC      : ${NIC}"
if [[ -n "${SYNC_HOST}" ]]; then
  echo " 동기화   : 이벤트 기반 (A=${SYNC_HOST})"
else
  echo " 동기화   : 타이머 기반 (${SCENARIO_WAIT}s/시나리오)"
  echo " 예상시간 : ${TOTAL_H}h ${TOTAL_M}m"
fi
echo "════════════════════════════════════════════════"
echo ""
echo "사전 확인:"
echo "  1) PTP 동기화 offset < ±1μs"
echo "  2) Laptop A에서 run_exp1_pub.sh 실행 후 대기 중"
echo ""
read -rp "준비 완료 후 Enter (Laptop A와 동시에)..."

# ── 동기화 함수 ──────────────────────────────────────────────────────────────

# A에 "DONE" 신호 전송 (시나리오 완료 후)
send_done_to_a() {
  local attempt
  for attempt in 1 2 3; do
    if echo "DONE" | nc -w5 "${SYNC_HOST}" "${SYNC_PORT}" 2>/dev/null; then
      echo "  [sync] DONE 전송 완료  $(date '+%H:%M:%S')"
      return 0
    fi
    echo "  [sync] DONE 전송 실패 (attempt ${attempt}/3), 재시도..."
    sleep 2
  done
  echo "  [sync][WARN] DONE 전송 실패 — A가 타임아웃 후 자동 전환"
}

# A의 "READY" 신호 수신 (publisher 전환 완료 후)
wait_ready_from_a() {
  echo "  [sync] A의 READY 신호 대기 중... (port ${SYNC_ACK_PORT}, timeout ${SYNC_TIMEOUT}s)"
  if nc -l -w "${SYNC_TIMEOUT}" -p "${SYNC_ACK_PORT}" > /dev/null 2>&1; then
    echo "  [sync] READY 수신  $(date '+%H:%M:%S')"
  else
    echo "  [sync][WARN] READY 대기 타임아웃 — 다음 시나리오로 진행"
  fi
}

# ── 메인 루프 ─────────────────────────────────────────────────────────────────

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

  # 마지막 시나리오는 동기화 불필요
  if [[ "${SCENARIO}" == "${SCENARIOS[-1]}" ]]; then
    continue
  fi

  if [[ -n "${SYNC_HOST}" ]]; then
    # 이벤트 기반: A에 완료 통보 후 READY 대기
    send_done_to_a
    wait_ready_from_a
  else
    # 타이머 기반: SCENARIO_WAIT 기준으로 남은 시간 대기
    REMAINING=$(( SCENARIO_WAIT - ELAPSED ))
    if (( REMAINING > 0 )); then
      echo "  다음 시나리오까지 ${REMAINING}s 대기 (Laptop A publisher 전환 중)..."
      sleep "${REMAINING}"
    fi
  fi
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
