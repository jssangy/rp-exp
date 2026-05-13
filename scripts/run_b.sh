#!/bin/bash
# Laptop B — single run
# usage: ./run_b.sh <scenario> <condition> <run>
# e.g.:  ./run_b.sh S3b rosbag2 1
#
# conditions: baseline | rp_hz | rp_bag | topic_hz | rosbag2
#
# 환경변수:
#   SYNC_HOST      : Laptop A wlan IP (설정 시 per-run pub 동기화)
#   SYNC_PORT      : B→A 포트 (기본 55001)
#   SYNC_ACK_PORT  : A→B 포트 (기본 55002)
#   NIC            : 측정 인터페이스 (미설정 시 자동 감지)

set -euo pipefail

# ROS 환경이 없으면 자동 소스
set +u
if ! command -v ros2 &>/dev/null; then
  source /opt/ros/humble/setup.bash
fi
SCRIPT_DIR_TMP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SETUP="$(dirname "${SCRIPT_DIR_TMP}")/install/setup.bash"
[[ -f "${INSTALL_SETUP}" ]] && source "${INSTALL_SETUP}"
set -u

export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-77}

SCENARIO=${1:?usage: $0 <scenario> <condition> <run>}
CONDITION=${2:?}
RUN=$(printf "%02d" "${3:?}")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
OUTDIR="${REPO_DIR}/results/exp1/${SCENARIO}/${CONDITION}/run${RUN}"
BAGDIR="${REPO_DIR}/bags/exp1/${SCENARIO}/${CONDITION}/run${RUN}"

NIC=${NIC:-$(ip route show default | awk '/default/ {print $5; exit}')}
SYNC_HOST=${SYNC_HOST:-""}
SYNC_PORT=${SYNC_PORT:-55001}
SYNC_ACK_PORT=${SYNC_ACK_PORT:-55002}

CLK_TCK=$(getconf CLK_TCK)
RP_BIN=${RP_BIN:-$(command -v rp)}
RP_SOCKET=${RP_SOCKET:-/tmp/ros2probe.sock}
OBS_PID=""
RP_PID=""
SUB_PID=""
NETDEV_PID=""
CPU_MEM_PID=""
PUBLISHER_STARTED=0
STOP_SENT=0

wait_for_rp_socket() {
  local timeout_decisec=${1:-100}
  local i

  for i in $(seq 1 "${timeout_decisec}"); do
    if [[ -S "${RP_SOCKET}" ]] && timeout 1 "${RP_BIN}" topic list >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "[ERROR] ros2probe command server not ready: ${RP_SOCKET}" >&2
  return 1
}

wait_pid_timeout() {
  local pid=${1:?}
  local timeout_s=${2:?}
  local i

  for i in $(seq 1 "${timeout_s}"); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

stop_pid_gracefully() {
  local pid=${1:?}
  local signal=${2:-TERM}
  local timeout_s=${3:-5}
  local use_sudo=${4:-0}

  if [[ "${use_sudo}" == "1" ]]; then
    sudo -n kill "-${signal}" -- "-${pid}" 2>/dev/null || true
    sudo -n kill "-${signal}" "${pid}" 2>/dev/null || true
  fi
  kill "-${signal}" -- "-${pid}" 2>/dev/null || true
  kill "-${signal}" "${pid}" 2>/dev/null || true
  wait_pid_timeout "${pid}" "${timeout_s}" || {
    if [[ "${use_sudo}" == "1" ]]; then
      sudo -n kill -KILL -- "-${pid}" 2>/dev/null || true
      sudo -n kill -KILL "${pid}" 2>/dev/null || true
    fi
    kill -KILL -- "-${pid}" 2>/dev/null || true
    kill -KILL "${pid}" 2>/dev/null || true
  }
  wait "${pid}" 2>/dev/null || true
}

stop_rp_runtime() {
  if [[ -n "${RP_PID}" ]]; then
    # `rp run` is started via sudo, so signal the run's process group with sudo.
    stop_pid_gracefully "${RP_PID}" INT 5 1
  fi
}

cleanup_on_exit() {
  if [[ "${PUBLISHER_STARTED}" == "1" && "${STOP_SENT}" == "0" && -n "${SYNC_HOST}" ]]; then
    echo "STOP" | nc -w5 "${SYNC_HOST}" "${SYNC_PORT}" 2>/dev/null || true
    STOP_SENT=1
  fi

  [[ -n "${OBS_PID}" ]] && stop_pid_gracefully "${OBS_PID}" INT 3
  [[ -n "${RP_PID}" ]] && stop_rp_runtime
  [[ -n "${CPU_MEM_PID}" ]] && stop_pid_gracefully "${CPU_MEM_PID}" TERM 2
  [[ -n "${NETDEV_PID}" ]] && stop_pid_gracefully "${NETDEV_PID}" TERM 2
  [[ -n "${SUB_PID}" ]] && stop_pid_gracefully "${SUB_PID}" TERM 3
}

trap cleanup_on_exit EXIT

# 시나리오별 설정
SUB_LAUNCH=""
case ${SCENARIO} in
  S1)  SUB_NODE="s1_sub";        TOPIC="/cmd_vel" ;;
  S2)  SUB_NODE="s2_sub";        TOPIC="/imu" ;;
  S3a) SUB_NODE="s3a_sub";       TOPIC="/scan" ;;
  S3b) SUB_NODE="s3_points_sub"; TOPIC="/points" ;;
  S3c) SUB_NODE="s3_points_sub"; TOPIC="/points" ;;
  S4a) SUB_NODE="s4a_sub";       TOPIC="/image_raw/compressed" ;;
  S4b) SUB_NODE="s4_image_sub";  TOPIC="/depth/image_raw" ;;
  S5a) SUB_NODE="";              SUB_LAUNCH="s5a_sub.launch.py"; TOPIC="/image_raw/compressed" ;;
  S5b) SUB_NODE="";              SUB_LAUNCH="s5b_sub.launch.py"; TOPIC="/points" ;;
  *) echo "[ERROR] unknown scenario: ${SCENARIO}"; exit 1 ;;
esac

if [[ ${SCENARIO} == S5* ]]; then
  BAG_TOPICS="--all"
else
  BAG_TOPICS="${TOPIC}"
fi

mkdir -p "${OUTDIR}"
echo "[run_b] ${SCENARIO}/${CONDITION}/run${RUN}  NIC=${NIC}  outdir=${OUTDIR}"

# ros2 daemon 잔재 제거
ros2 daemon stop 2>/dev/null || true

# ── Step 1: observer 도구 먼저 실행 (DDS discovery 전에 프로빙 시작) ──────────
case ${CONDITION} in
  topic_hz)
    setsid ros2 topic hz "${TOPIC}" > "${OUTDIR}/obs.log" 2>&1 &
    OBS_PID=$!
    ;;
  rosbag2)
    mkdir -p "${BAGDIR}"
    setsid ros2 bag record ${BAG_TOPICS} --storage mcap -o "${BAGDIR}/rosbag2" > "${OUTDIR}/obs.log" 2>&1 &
    OBS_PID=$!
    ;;
  rp_hz)
    sudo -n rm -f "${RP_SOCKET}" 2>/dev/null || rm -f "${RP_SOCKET}" 2>/dev/null || true
    setsid sudo -n "${RP_BIN}" run > "${OUTDIR}/obs.log" 2>&1 &
    RP_PID=$!
    if ! wait_for_rp_socket 100; then
      stop_rp_runtime
      exit 1
    fi
    setsid "${RP_BIN}" topic hz "${TOPIC}" >> "${OUTDIR}/obs.log" 2>&1 &
    OBS_PID=$!
    ;;
  rp_bag)
    mkdir -p "${BAGDIR}"
    sudo -n rm -f "${RP_SOCKET}" 2>/dev/null || rm -f "${RP_SOCKET}" 2>/dev/null || true
    setsid sudo -n "${RP_BIN}" run > "${OUTDIR}/obs.log" 2>&1 &
    RP_PID=$!
    if ! wait_for_rp_socket 100; then
      stop_rp_runtime
      exit 1
    fi
    setsid "${RP_BIN}" bag record ${BAG_TOPICS} -o "${BAGDIR}/rp.mcap" >> "${OUTDIR}/obs.log" 2>&1 &
    OBS_PID=$!
    ;;
  baseline)
    ;;
  *)
    echo "[ERROR] unknown condition: ${CONDITION}"; exit 1
    ;;
esac

# ── Step 2: Laptop A에 publisher 시작 요청 ────────────────────────────────────
if [[ -n "${SYNC_HOST}" ]]; then
  echo "  [sync] START ${SCENARIO} 전송..."
  echo "START ${SCENARIO}" | nc -w5 "${SYNC_HOST}" "${SYNC_PORT}" 2>/dev/null || true
  timeout 30 nc -l -p "${SYNC_ACK_PORT}" > /dev/null 2>&1 || true
  echo "  [sync] Publisher 준비 완료  $(date '+%H:%M:%S')"
  PUBLISHER_STARTED=1
else
  echo "  [warn] SYNC_HOST 미설정 — publisher가 이미 실행 중이어야 함"
fi

# ── Step 3: subscriber 백그라운드 실행 (10s warmup 내장) ──────────────────────
if [[ -n "${SUB_LAUNCH}" ]]; then
  setsid ros2 launch test "${SUB_LAUNCH}" > "${OUTDIR}/sub.log" &
else
  setsid ros2 run test "${SUB_NODE}" > "${OUTDIR}/sub.log" &
fi
SUB_PID=$!

# ── Step 4: warmup 대기 후 netdev + CPU/메모리 샘플링 시작 ───────────────────
sleep 10

# /proc/net/dev 샘플링
(
  while true; do
    grep " ${NIC}:" /proc/net/dev \
      | awk -v t="$(date +%s%3N)" '{print t, $2}'
    sleep 1
  done
) > "${OUTDIR}/netdev.log" &
NETDEV_PID=$!

# 시스템 전체 CPU/메모리 샘플링 (모든 조건에서 실행)
# 출력: timestamp_ms  cpu%  used_kb
# CPU%: /proc/stat idle 델타 기반, 메모리: /proc/meminfo MemTotal-MemAvailable
(
  set +e
  prev=$(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
  prev_total=$(echo "${prev}" | awk '{print $1}')
  prev_idle=$(echo "${prev}"  | awk '{print $2}')

  while true; do
    sleep 1
    curr_t=$(date +%s%3N)
    curr=$(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
    curr_total=$(echo "${curr}" | awk '{print $1}')
    curr_idle=$(echo "${curr}"  | awk '{print $2}')
    delta_total=$(( curr_total - prev_total ))
    delta_idle=$(( curr_idle  - prev_idle  ))
    [[ ${delta_total} -le 0 ]] && delta_total=1
    cpu_pct=$(awk "BEGIN {printf \"%.1f\", (1 - ${delta_idle}/${delta_total}) * 100}")
    used_kb=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print t-a}' /proc/meminfo)
    echo "${curr_t} ${cpu_pct} ${used_kb}"
    prev_total=${curr_total}
    prev_idle=${curr_idle}
  done
) > "${OUTDIR}/cpu_mem.log" &
CPU_MEM_PID=$!

# ── Step 5: subscriber 종료 대기 (60s 측정 후 자동 종료) ──────────────────────
wait "${SUB_PID}" 2>/dev/null || true
echo "  [sub] 완료  $(date '+%H:%M:%S')"

# ── Step 6: Laptop A에 publisher 종료 요청 ───────────────────────────────────
if [[ -n "${SYNC_HOST}" ]]; then
  echo "STOP" | nc -w5 "${SYNC_HOST}" "${SYNC_PORT}" 2>/dev/null || true
  STOP_SENT=1
fi

# ── Step 7: 백그라운드 프로세스 정리 ─────────────────────────────────────────
case ${CONDITION} in
  rp_hz|rp_bag)
    # rp CLI sends TopicHzStop/BagStop only on Ctrl-C (SIGINT), not SIGTERM.
    [[ -n "${OBS_PID}" ]] && stop_pid_gracefully "${OBS_PID}" INT 10
    stop_rp_runtime 5
    ;;
  rosbag2)
    # Let rosbag2 close metadata/storage cleanly.
    [[ -n "${OBS_PID}" ]] && stop_pid_gracefully "${OBS_PID}" INT 10
    ;;
  topic_hz)
    [[ -n "${OBS_PID}" ]] && stop_pid_gracefully "${OBS_PID}" INT 5
    ;;
esac

[[ -n "${CPU_MEM_PID}" ]] && stop_pid_gracefully "${CPU_MEM_PID}" TERM 3
kill "${NETDEV_PID}" 2>/dev/null || true
wait "${NETDEV_PID}" 2>/dev/null || true

# ── Step 8: 이번 run에서 시작한 subscriber/launch group 정리 ───────────────
[[ -n "${SUB_PID}" ]] && stop_pid_gracefully "${SUB_PID}" TERM 5
ros2 daemon stop 2>/dev/null || true

echo "[run_b] run${RUN} done → ${OUTDIR}"
trap - EXIT
sleep 10
