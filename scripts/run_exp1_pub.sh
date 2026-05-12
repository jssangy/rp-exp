#!/bin/bash
# Laptop A — Experiment 1 publisher 자동 관리
#
# 사용법:
#   ./scripts/run_exp1_pub.sh --sync <Laptop-B-wlan-IP>   # 이벤트 기반 (권장)
#   ./scripts/run_exp1_pub.sh                             # 타이머 기반 (레거시)
#
# 이벤트 기반 (--sync):
#   B가 run마다 "START <scenario>" / "STOP" / "DONE" 을 전송
#   A가 pub 시작/종료를 각 run에 맞게 제어
#   B → A: port 55001 / A → B: port 55002
#
# 타이머 기반:
#   시나리오당 SCENARIO_WAIT 동안 publisher 유지 (--sync 없을 때)

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
source /opt/ros/humble/setup.bash
source "${REPO_DIR}/install/setup.bash"
set -u
export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-77}

# ── 환경 설정 (CPU governor, chrony NTP 서버) ────────────────────────────────
setup_env() {
  echo "[setup] CPU governor → performance"
  sudo cpupower frequency-set -g performance 2>/dev/null \
    || echo "  [warn] cpupower 실패 (무시)"

  echo "[setup] chrony NTP 서버 설정..."
  # 이전에 추가한 항목 제거 후 재추가
  sudo sed -i '/#rp-exp/d' /etc/chrony/chrony.conf
  echo "local stratum 1  #rp-exp" | sudo tee -a /etc/chrony/chrony.conf > /dev/null
  echo "allow 0/0         #rp-exp" | sudo tee -a /etc/chrony/chrony.conf > /dev/null
  sudo systemctl restart chrony
  echo "  [setup] chronyd NTP 서버 시작됨  $(date '+%H:%M:%S')"
}

# ── Publisher 제어 ────────────────────────────────────────────────────────────

PUB_PID=""

stop_current() {
  if [[ -n "${PUB_PID}" ]]; then
    echo "[pub] 종료 (PID ${PUB_PID})  $(date '+%H:%M:%S')"
    # ros2 run/launch 먼저 종료 → pub_a.sh(bash)가 포그라운드 명령 대기에서 풀림
    pkill -SIGTERM -f "ros2 run test .*pub"    2>/dev/null || true
    pkill -SIGTERM -f "ros2 launch test .*pub" 2>/dev/null || true
    sleep 1
    pkill -SIGKILL -f "ros2 run test .*pub"    2>/dev/null || true
    pkill -SIGKILL -f "ros2 launch test .*pub" 2>/dev/null || true
    kill "${PUB_PID}" 2>/dev/null || true
    wait "${PUB_PID}" 2>/dev/null || true
    PUB_PID=""
  fi
}
trap stop_current EXIT

# ── 이벤트 기반 모드 ──────────────────────────────────────────────────────────

run_event_driven() {
  echo "════════════════════════════════════════════════"
  echo " Experiment 1 — Laptop A (Publisher, 이벤트 기반)"
  echo " B wlan IP : ${SYNC_HOST}"
  echo " 수신 포트 : ${SYNC_PORT}  응답 포트: ${SYNC_ACK_PORT}"
  echo "════════════════════════════════════════════════"
  echo ""

  setup_env

  echo ""
  echo " B의 명령을 대기합니다. Laptop B에서 run_exp1_sub.sh 실행 후"
  echo " 양쪽 동시에 Enter를 눌러 시작하세요."
  echo ""
  read -rp "준비 완료 후 Enter..."

  while true; do
    CMD=$(nc -l -p "${SYNC_PORT}" 2>/dev/null || true)
    CMD="${CMD%%$'\r'}"  # carriage return 제거

    case "${CMD}" in
      START\ *)
        SCENARIO="${CMD#START }"
        stop_current
        echo ""
        echo "  [$(date '+%H:%M:%S')] ${SCENARIO} publisher 시작"
        bash "${SCRIPT_DIR}/pub_a.sh" "${SCENARIO}" &
        PUB_PID=$!
        sleep 1  # pub 초기화 대기
        echo "READY" | nc -w5 "${SYNC_HOST}" "${SYNC_ACK_PORT}" 2>/dev/null || true
        ;;
      STOP)
        echo "  [$(date '+%H:%M:%S')] publisher 종료 요청"
        stop_current
        ;;
      DONE)
        echo ""
        echo "════════════════════════════════════════════════"
        echo " Experiment 1 (Laptop A) 완료  $(date '+%H:%M:%S')"
        echo "════════════════════════════════════════════════"
        break
        ;;
      "")
        ;;
      *)
        echo "[WARN] 알 수 없는 명령: '${CMD}'"
        ;;
    esac
  done
}

# ── 타이머 기반 모드 (레거시) ─────────────────────────────────────────────────

run_timer_based() {
  SECS_PER_RUN=80
  SCENARIO_WAIT=$(( 5 * N_RUNS * SECS_PER_RUN + BUFFER_S ))
  TOTAL_SECS=$(( ${#SCENARIOS[@]} * SCENARIO_WAIT ))
  TOTAL_H=$(( TOTAL_SECS / 3600 ))
  TOTAL_M=$(( (TOTAL_SECS % 3600) / 60 ))

  echo "════════════════════════════════════════════════"
  echo " Experiment 1 — Laptop A (Publisher, 타이머 기반)"
  echo " 시나리오  : ${SCENARIOS[*]}"
  echo " 반복      : ${N_RUNS}회"
  echo " 시나리오당: ${SCENARIO_WAIT}s"
  echo " 예상시간  : ${TOTAL_H}h ${TOTAL_M}m"
  echo "════════════════════════════════════════════════"
  echo ""

  setup_env

  echo ""
  echo " Laptop B에서 run_exp1_sub.sh 를 실행하고"
  echo " 양쪽 동시에 Enter를 눌러 시작하세요."
  echo ""
  read -rp "준비 완료 후 Enter..."

  for SCENARIO in "${SCENARIOS[@]}"; do
    echo ""
    echo "════════════════════════════════════════"
    echo " [$(date '+%H:%M:%S')] 시나리오: ${SCENARIO}"
    echo "════════════════════════════════════════"

    bash "${SCRIPT_DIR}/pub_a.sh" "${SCENARIO}" &
    PUB_PID=$!
    echo "[pub] 시작 (PID ${PUB_PID})"

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
}

# ── 실행 ──────────────────────────────────────────────────────────────────────

if [[ -n "${SYNC_HOST}" ]]; then
  run_event_driven
else
  run_timer_based
fi
