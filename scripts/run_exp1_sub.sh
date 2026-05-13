#!/bin/bash
# Laptop B — Experiment 1 전체 자동 실행
#
# 사용법:
#   ./scripts/run_exp1_sub.sh --sync <Laptop-A-IP>   # 이벤트 기반 (권장)
#   ./scripts/run_exp1_sub.sh                        # 타이머 기반 (레거시)
#
# 이벤트 기반: run마다 A에 START/STOP 전송 → pub 생명주기 정밀 제어
# 타이머 기반: SCENARIO_WAIT 동안 대기 (--sync 없을 때)
#
# --sync IP는 ethernet 또는 WiFi 모두 사용 가능
# chrony 서버도 동일 IP 사용 (CHRONY_SERVER 환경변수로 오버라이드 가능)

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
# chrony 서버 IP (기본: SYNC_HOST, 오버라이드 가능)
CHRONY_SERVER=${CHRONY_SERVER:-${SYNC_HOST}}
export NIC
export SYNC_HOST
export SYNC_PORT
export SYNC_ACK_PORT

SUDO_KEEPALIVE_PID=""
CLEANED_UP=0

start_sudo_keepalive() {
  echo "[setup] sudo 권한 확인 (실험 중 재입력 방지)"
  sudo -v
  (
    while true; do
      sudo -n true 2>/dev/null || exit
      sleep 60
    done
  ) >/dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!
}

stop_sudo_keepalive() {
  if [[ -n "${SUDO_KEEPALIVE_PID}" ]]; then
    kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
    wait "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
  fi
}

# ── 환경 설정 (CPU governor, chrony NTP 클라이언트) ──────────────────────────
setup_env() {
  echo "[setup] CPU governor → performance"
  sudo cpupower frequency-set -g performance 2>/dev/null \
    || echo "  [warn] cpupower 실패 (무시)"

  if [[ -z "${CHRONY_SERVER}" ]]; then
    echo "  [warn] CHRONY_SERVER 미설정 — 클록 동기화 건너뜀"
    return 0
  fi

  echo "[setup] chrony NTP 클라이언트 설정 (서버: ${CHRONY_SERVER})..."
  # 기존 drop-in 파일 제거 (이전 실행 잔재)
  sudo rm -f /etc/chrony/conf.d/rp-exp.conf /etc/chrony/sources.d/rp-exp.sources
  # chrony 정상 기동 확인 후 런타임으로 서버 추가 (재시작 불필요)
  sudo systemctl is-active chrony > /dev/null 2>&1 || sudo systemctl start chrony
  sleep 1
}

force_chrony_source() {
  if [[ -z "${CHRONY_SERVER}" ]]; then
    return 0
  fi

  sudo chronyc add server "${CHRONY_SERVER}" iburst prefer > /dev/null 2>&1 || true
  sudo chronyc reload sources > /dev/null 2>&1 || true

  # 실험 중에는 Laptop A만 시간 기준으로 사용한다.
  sudo chronyc offline > /dev/null 2>&1 || true
  sudo chronyc online "${CHRONY_SERVER}" > /dev/null 2>&1 || true
}

sync_clock_for_condition() {
  local label=${1:?}

  if [[ -z "${CHRONY_SERVER}" ]]; then
    return 0
  fi

  echo "  [clock] ${label}: Laptop A(${CHRONY_SERVER}) source 강제 및 동기화 확인"
  force_chrony_source

  # iburst 응답을 받은 뒤 스텝 동기화
  sleep 3
  sudo chronyc makestep 2>/dev/null || true

  echo "  [clock] source=${CHRONY_SERVER}, 목표: |offset| < 1ms"
  local offset_sec abs_offset_ms selected_source
  for i in $(seq 1 180); do
    offset_sec=$(chronyc tracking 2>/dev/null \
                 | awk '/Last offset/{print $4}')
    selected_source=$(chronyc sources -n 2>/dev/null \
                      | awk '$1 ~ /^\^\*/ {print $2; exit}')
    if [[ -n "${offset_sec}" ]]; then
      abs_offset_ms=$(awk "BEGIN{v=${offset_sec}+0; if(v<0)v=-v; printf \"%.3f\", v*1000}")
      if (( i == 1 || i % 5 == 0 )); then
        echo "  [clock] wait=${i}s selected=${selected_source:-?} offset=${abs_offset_ms}ms"
      fi
      if [[ "${selected_source}" == "${CHRONY_SERVER}" ]] && \
         awk "BEGIN{v=${offset_sec}+0; if(v<0)v=-v; exit !(v < 0.001)}"; then
        echo "  [clock] 동기화 완료 (offset=${offset_sec} s)  $(date '+%H:%M:%S')"
        return 0
      fi
    else
      if (( i == 1 || i % 5 == 0 )); then
        echo "  [clock] wait=${i}s server not connected"
      fi
    fi
    sleep 1
  done
  echo "  [ERROR] ${label}: 180s 내 동기화 실패 (selected=${selected_source:-?}, offset=${offset_sec:-?} s)"
  return 1
}

restore_ntp() {
  if [[ -n "${CHRONY_SERVER}" ]]; then
    sudo -n chronyc online > /dev/null 2>&1 || true
  fi
}

cleanup() {
  [[ "${CLEANED_UP}" == "1" ]] && return
  CLEANED_UP=1
  restore_ntp
  stop_sudo_keepalive
}

handle_signal() {
  trap - INT TERM
  echo ""
  echo "[interrupt] 중단 요청 수신, 정리 중..."
  exit 130
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

trap cleanup EXIT
trap handle_signal INT TERM
start_sudo_keepalive
setup_env

echo ""
echo "사전 확인:"
echo "  1) Laptop A에서 run_exp1_pub.sh --sync <B-wlan-IP> 실행 후 대기 중"
echo ""
if [[ -n "${SYNC_HOST}" ]]; then
  echo "이벤트 기반 동기화 모드: Enter 대기 없이 바로 시작합니다."
else
  read -rp "준비 완료 후 Enter (Laptop A와 동시에)..."
fi

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
    if ! sync_clock_for_condition "${SCENARIO}/${CONDITION}"; then
      echo "  [ERROR] clock sync failed; aborting experiment"
      exit 1
    fi
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
