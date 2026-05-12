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
# PTP용 유선 NIC (기본: 이름이 e로 시작하는 첫 번째 인터페이스)
PTP_NIC=${PTP_NIC:-$(ip link show | awk -F': ' '/^[0-9]+: e/{print $2; exit}')}
export NIC
export SYNC_HOST
export SYNC_PORT
export SYNC_ACK_PORT

# ── 환경 설정 (CPU governor, PTP slave) ──────────────────────────────────────
setup_env() {
  echo "[setup] CPU governor → performance"
  sudo cpupower frequency-set -g performance 2>/dev/null \
    || echo "  [warn] cpupower 실패 (무시)"

  echo "[setup] PTP 기존 프로세스 정리..."
  sudo pkill ptp4l   2>/dev/null || true
  sudo pkill phc2sys 2>/dev/null || true
  sleep 1

  # PHC(하드웨어 클록) 존재 여부 확인
  local phc_dev
  phc_dev=$(ls /dev/ptp* 2>/dev/null | head -1 || true)

  if [[ -n "${phc_dev}" ]]; then
    echo "[setup] ptp4l slave 시작 (NIC=${PTP_NIC}, HW timestamp)..."
    sudo ptp4l -i "${PTP_NIC}" -s -m > /tmp/ptp4l_slave.log 2>&1 &
    sleep 2
    echo "[setup] phc2sys 시작 (PHC → 시스템 클록)..."
    sudo phc2sys -s "${PTP_NIC}" -c CLOCK_REALTIME -m > /tmp/phc2sys.log 2>&1 &
    # 시스템 클록 offset 확인 (phc2sys 로그)
    _wait_ptp_converge /tmp/phc2sys.log "phc offset"
  else
    echo "[setup] PHC 없음 → SW timestamp 모드"
    sudo ptp4l -i "${PTP_NIC}" -s -m -S > /tmp/ptp4l_slave.log 2>&1 &
    # -S 모드: ptp4l이 CLOCK_REALTIME 직접 제어, phc2sys 불필요
    _wait_ptp_converge /tmp/ptp4l_slave.log "master offset"
  fi
}

_wait_ptp_converge() {
  local logfile=$1
  local pattern=$2
  local offset="" abs_offset=""
  echo "[setup] PTP 수렴 대기 (목표: |offset| < 1ms)..."
  for i in $(seq 1 120); do
    offset=$(grep "${pattern}" "${logfile}" 2>/dev/null | tail -1 \
             | grep -oP '(?<=offset\s{0,8})-?\d+' || true)
    if [[ -n "${offset}" ]]; then
      abs_offset=$(( offset < 0 ? -offset : offset ))
      printf "\r  대기 중... %3ds  offset=%d ns      " "${i}" "${offset}"
      if (( abs_offset < 1000000 )); then
        echo ""
        echo "  [setup] PTP 수렴 완료 (offset=${offset} ns)  $(date '+%H:%M:%S')"
        return 0
      fi
    else
      printf "\r  대기 중... %3ds  (master 미감지)    " "${i}"
    fi
    sleep 1
  done
  echo ""
  echo "  [warn] PTP 120s 내 수렴 실패 (offset=${offset:-?} ns)"
  echo "  [hint] 확인: sudo tcpdump -i ${PTP_NIC} udp port 319 or port 320"
  echo "  [hint] A가 먼저 실행됐는지 확인. 계속 진행합니다..."
}

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

setup_env

echo ""
echo "사전 확인:"
echo "  1) Laptop A에서 run_exp1_pub.sh 실행 후 대기 중"
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
