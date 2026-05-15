#!/bin/bash
# Receiver Platform - Experiment 3 single run
# usage: ./run_exp3_b.sh <platform> <scenario> <condition> <run>
# scenarios: ST100 | ST500 | ST1000
# conditions: baseline | rp_hz | topic_hz

set -euo pipefail

normalize_tty() {
  [[ -t 1 ]] && stty sane opost onlcr 2>/dev/null || true
}

normalize_tty

set +u
if ! command -v ros2 &>/dev/null; then
  source /opt/ros/humble/setup.bash
fi
SCRIPT_DIR_TMP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SETUP="$(dirname "${SCRIPT_DIR_TMP}")/install/setup.bash"
[[ -f "${INSTALL_SETUP}" ]] && source "${INSTALL_SETUP}"
set -u

export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-79}

PLATFORM=${1:?usage: $0 <platform> <scenario> <condition> <run>}
SCENARIO=${2:?}
CONDITION=${3:?}
RUN=$(printf "%02d" "${4:?}")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
OUTDIR="${REPO_DIR}/results/exp3/${PLATFORM}/${SCENARIO}/${CONDITION}/run${RUN}"

NIC=${NIC:-$(ip route show default | awk '/default/ {print $5; exit}')}
SYNC_HOST=${SYNC_HOST:-""}
SYNC_PORT=${SYNC_PORT:-56001}
SYNC_ACK_PORT=${SYNC_ACK_PORT:-56002}
RP_BIN=${RP_BIN:-$(command -v rp)}
RP_SOCKET=${RP_SOCKET:-/tmp/ros2probe.sock}
TOPIC=${STRESS_TOPIC:-/stress}
PAYLOAD_BYTES=${STRESS_PAYLOAD_BYTES:-65536}
WARMUP_SEC=${WARMUP_SEC:-10}
MEASURE_SEC=${MEASURE_SEC:-60}
CLK_TCK=$(getconf CLK_TCK)

case ${SCENARIO} in
  ST100)  HZ=100 ;;
  ST500)  HZ=500 ;;
  ST1000) HZ=1000 ;;
  *) echo "[ERROR] unknown scenario: ${SCENARIO}"; exit 1 ;;
esac

OBS_PID=""
RP_PID=""
SUB_PID=""
NETDEV_PID=""
OBSERVER_CPU_PID=""
PUBLISHER_STARTED=0
STOP_SENT=0
CLEANED_UP=0

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
    stop_pid_gracefully "${RP_PID}" INT 5 1
  fi
}

cleanup_on_exit() {
  [[ "${CLEANED_UP}" == "1" ]] && return
  CLEANED_UP=1
  normalize_tty

  if [[ "${PUBLISHER_STARTED}" == "1" && "${STOP_SENT}" == "0" && -n "${SYNC_HOST}" ]]; then
    echo "STOP" | nc -w5 "${SYNC_HOST}" "${SYNC_PORT}" 2>/dev/null || true
    STOP_SENT=1
  fi

  [[ -n "${OBSERVER_CPU_PID}" ]] && stop_pid_gracefully "${OBSERVER_CPU_PID}" TERM 2
  [[ -n "${NETDEV_PID}" ]] && stop_pid_gracefully "${NETDEV_PID}" TERM 2
  [[ -n "${OBS_PID}" ]] && stop_pid_gracefully "${OBS_PID}" INT 5
  [[ -n "${RP_PID}" ]] && stop_rp_runtime
  [[ -n "${SUB_PID}" ]] && stop_pid_gracefully "${SUB_PID}" TERM 3
}

handle_signal() {
  trap - INT TERM
  normalize_tty
  echo ""
  echo "[interrupt] run stop requested"
  cleanup_on_exit
  exit 130
}

trap cleanup_on_exit EXIT
trap handle_signal INT TERM

mkdir -p "${OUTDIR}"
echo "[run_exp3_b] ${PLATFORM}/${SCENARIO}/${CONDITION}/run${RUN}  NIC=${NIC}  outdir=${OUTDIR}"

{
  echo "platform=${PLATFORM}"
  echo "scenario=${SCENARIO}"
  echo "condition=${CONDITION}"
  echo "hz=${HZ}"
  echo "payload_bytes=${PAYLOAD_BYTES}"
  echo "topic=${TOPIC}"
  echo "ros_domain_id=${ROS_DOMAIN_ID}"
  echo "nic=${NIC}"
  echo "date=$(date -Is)"
  echo "kernel=$(uname -a)"
  echo "logical_cores=$(nproc)"
  if command -v cpupower >/dev/null 2>&1; then
    cpupower frequency-info -p 2>/dev/null || true
  fi
  if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    echo "cpu0_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
  fi
} > "${OUTDIR}/platform.log"

ros2 daemon stop 2>/dev/null || true

case ${CONDITION} in
  topic_hz)
    setsid ros2 topic hz "${TOPIC}" > "${OUTDIR}/obs.log" 2>&1 &
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
  baseline)
    ;;
  *)
    echo "[ERROR] unknown condition: ${CONDITION}"; exit 1 ;;
esac

if [[ -n "${SYNC_HOST}" ]]; then
  echo "  [sync] sending START ${SCENARIO}..."
  echo "START ${SCENARIO}" | nc -w5 "${SYNC_HOST}" "${SYNC_PORT}" 2>/dev/null || true
  timeout 30 nc -l -p "${SYNC_ACK_PORT}" > /dev/null 2>&1 || true
  echo "  [sync] Publisher ready  $(date '+%H:%M:%S')"
  PUBLISHER_STARTED=1
else
  echo "  [warn] SYNC_HOST is not set; publisher must already be running"
fi

setsid ros2 run test stress_sub "${HZ}" "${WARMUP_SEC}" "${MEASURE_SEC}" "${TOPIC}" > "${OUTDIR}/sub.log" 2>&1 &
SUB_PID=$!

sleep "${WARMUP_SEC}"

(
  while true; do
    grep " ${NIC}:" /proc/net/dev \
      | awk -v t="$(date +%s%3N)" '{print t, $2}'
    sleep 1
  done
) > "${OUTDIR}/netdev.log" &
NETDEV_PID=$!

(
  set +e
  prev_total=0
  prev_ts=$(date +%s%3N)
  while true; do
    pids=()
    if [[ -n "${RP_PID}" ]]; then
      while read -r p; do [[ -n "${p}" ]] && pids+=("${p}"); done < <(pgrep -g "${RP_PID}" 2>/dev/null || true)
    fi
    if [[ -n "${OBS_PID}" ]]; then
      while read -r p; do [[ -n "${p}" ]] && pids+=("${p}"); done < <(pgrep -g "${OBS_PID}" 2>/dev/null || true)
    fi

    total=0
    alive=0
    for p in "${pids[@]}"; do
      if [[ -r "/proc/${p}/stat" ]]; then
        vals=$(awk '{print $14, $15}' "/proc/${p}/stat" 2>/dev/null || true)
        if [[ -n "${vals}" ]]; then
          u=$(echo "${vals}" | awk '{print $1}')
          s=$(echo "${vals}" | awk '{print $2}')
          total=$(( total + u + s ))
          alive=$(( alive + 1 ))
        fi
      fi
    done

    now=$(date +%s%3N)
    dt_ms=$(( now - prev_ts ))
    delta=$(( total - prev_total ))
    if [[ ${dt_ms} -le 0 ]]; then dt_ms=1; fi
    cpu_pct=$(awk "BEGIN {printf \"%.2f\", (${delta}/${CLK_TCK}) / (${dt_ms}/1000.0) * 100.0}")
    echo "${now} ${cpu_pct} ${alive} ${pids[*]}"
    prev_total=${total}
    prev_ts=${now}
    sleep 1
  done
) > "${OUTDIR}/observer_cpu.log" &
OBSERVER_CPU_PID=$!

wait "${SUB_PID}" 2>/dev/null || true
echo "  [sub] complete  $(date '+%H:%M:%S')"

if [[ -n "${SYNC_HOST}" ]]; then
  echo "STOP" | nc -w5 "${SYNC_HOST}" "${SYNC_PORT}" 2>/dev/null || true
  STOP_SENT=1
fi

case ${CONDITION} in
  rp_hz)
    [[ -n "${OBS_PID}" ]] && stop_pid_gracefully "${OBS_PID}" INT 10
    stop_rp_runtime
    ;;
  topic_hz)
    [[ -n "${OBS_PID}" ]] && stop_pid_gracefully "${OBS_PID}" INT 5
    ;;
esac

[[ -n "${OBSERVER_CPU_PID}" ]] && stop_pid_gracefully "${OBSERVER_CPU_PID}" TERM 3
[[ -n "${NETDEV_PID}" ]] && stop_pid_gracefully "${NETDEV_PID}" TERM 3
[[ -n "${SUB_PID}" ]] && stop_pid_gracefully "${SUB_PID}" TERM 5
ros2 daemon stop 2>/dev/null || true

echo "[run_exp3_b] run${RUN} done -> ${OUTDIR}"
trap - EXIT
sleep 10
