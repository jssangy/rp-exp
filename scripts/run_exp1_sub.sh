#!/bin/bash
# Laptop B - Experiment 1 runner
#
# Usage:
#   ./scripts/run_exp1_sub.sh --sync <Laptop-A-IP>   # event-driven mode
#   ./scripts/run_exp1_sub.sh                        # timer-based legacy mode
#
# Event mode: send START/STOP to Laptop A for every run.
# Timer mode: wait for SCENARIO_WAIT when --sync is not used.
#
# --sync IP can be Ethernet or Wi-Fi.
# The same IP is used as the chrony server unless CHRONY_SERVER overrides it.

set -euo pipefail

normalize_tty() {
  [[ -t 1 ]] && stty sane opost onlcr 2>/dev/null || true
}

normalize_tty

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
# Chrony server IP. Defaults to SYNC_HOST and can be overridden.
CHRONY_SERVER=${CHRONY_SERVER:-${SYNC_HOST}}
# Signed chrony offset acceptance window in seconds.
# Default target: 0 < Last offset < 1ms.
CHRONY_MIN_OFFSET_SEC=${CHRONY_MIN_OFFSET_SEC:-0}
CHRONY_MAX_OFFSET_SEC=${CHRONY_MAX_OFFSET_SEC:-0.001}
export NIC
export SYNC_HOST
export SYNC_PORT
export SYNC_ACK_PORT

SUDO_KEEPALIVE_PID=""
CLEANED_UP=0
CURRENT_RUN_PID=""

start_sudo_keepalive() {
  echo "[setup] Checking sudo credentials for unattended execution"
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

stop_current_run() {
  if [[ -n "${CURRENT_RUN_PID}" ]]; then
    kill -INT -- "-${CURRENT_RUN_PID}" 2>/dev/null || true
    kill -INT "${CURRENT_RUN_PID}" 2>/dev/null || true
    wait_pid_timeout "${CURRENT_RUN_PID}" 8 || {
      kill -TERM -- "-${CURRENT_RUN_PID}" 2>/dev/null || true
      kill -TERM "${CURRENT_RUN_PID}" 2>/dev/null || true
      wait_pid_timeout "${CURRENT_RUN_PID}" 3 || {
        kill -KILL -- "-${CURRENT_RUN_PID}" 2>/dev/null || true
        kill -KILL "${CURRENT_RUN_PID}" 2>/dev/null || true
      }
    }
    wait "${CURRENT_RUN_PID}" 2>/dev/null || true
    CURRENT_RUN_PID=""
  fi
}

# Environment setup: CPU governor and chrony NTP client.
setup_env() {
  echo "[setup] CPU governor -> performance"
  sudo cpupower frequency-set -g performance 2>/dev/null \
    || echo "  [warn] cpupower failed; continuing"

  if [[ -z "${CHRONY_SERVER}" ]]; then
    echo "  [warn] CHRONY_SERVER is not set; skipping clock sync"
    return 0
  fi

  echo "[setup] Configuring chrony NTP client (server: ${CHRONY_SERVER})..."
  # Remove stale drop-in files from previous runs.
  sudo rm -f /etc/chrony/conf.d/rp-exp.conf /etc/chrony/sources.d/rp-exp.sources
  # Ensure chrony is running, then add the server at runtime.
  sudo systemctl is-active chrony > /dev/null 2>&1 || sudo systemctl start chrony
  sleep 1
}

force_chrony_source() {
  if [[ -z "${CHRONY_SERVER}" ]]; then
    return 0
  fi

  sudo chronyc add server "${CHRONY_SERVER}" iburst prefer > /dev/null 2>&1 || true
  sudo chronyc reload sources > /dev/null 2>&1 || true

  # During the experiment, use Laptop A as the only time source.
  sudo chronyc offline > /dev/null 2>&1 || true
  sudo chronyc online "${CHRONY_SERVER}" > /dev/null 2>&1 || true
}

sync_clock_for_condition() {
  local label=${1:?}

  if [[ -z "${CHRONY_SERVER}" ]]; then
    return 0
  fi

  echo "  [clock] ${label}: forcing Laptop A (${CHRONY_SERVER}) and checking sync"
  force_chrony_source

  # Wait for iburst responses before stepping the clock.
  sleep 3
  sudo chronyc makestep 2>/dev/null || true

  echo "  [clock] source=${CHRONY_SERVER}, target: ${CHRONY_MIN_OFFSET_SEC}s < offset < ${CHRONY_MAX_OFFSET_SEC}s"
  local offset_sec offset_ms selected_source
  for i in $(seq 1 180); do
    offset_sec=$(chronyc tracking 2>/dev/null \
                 | awk '/Last offset/{print $4}')
    selected_source=$(chronyc sources -n 2>/dev/null \
                      | awk '$1 ~ /^\^\*/ {print $2; exit}')
    if [[ -n "${offset_sec}" ]]; then
      offset_ms=$(awk "BEGIN{v=${offset_sec}+0; printf \"%.3f\", v*1000}")
      if (( i == 1 || i % 5 == 0 )); then
        echo "  [clock] wait=${i}s selected=${selected_source:-?} offset=${offset_ms}ms"
      fi
      if [[ "${selected_source}" == "${CHRONY_SERVER}" ]] && \
         awk "BEGIN{v=${offset_sec}+0; min=${CHRONY_MIN_OFFSET_SEC}+0; max=${CHRONY_MAX_OFFSET_SEC}+0; exit !(v > min && v < max)}"; then
        echo "  [clock] sync complete (offset=${offset_sec} s)  $(date '+%H:%M:%S')"
        return 0
      fi
    else
      if (( i == 1 || i % 5 == 0 )); then
        echo "  [clock] wait=${i}s server not connected"
      fi
    fi
    sleep 1
  done
  echo "  [ERROR] ${label}: clock sync failed within 180s (target=${CHRONY_MIN_OFFSET_SEC}s<offset<${CHRONY_MAX_OFFSET_SEC}s, selected=${selected_source:-?}, offset=${offset_sec:-?} s)"
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
  normalize_tty
  stop_current_run
  restore_ntp
  stop_sudo_keepalive
}

handle_signal() {
  trap - INT TERM
  normalize_tty
  echo ""
  echo "[interrupt] stop requested; cleaning up..."
  exit 130
}

# Time estimate per run: 2s pub ready + 10s warmup + 60s measure + 2s stop + 10s sleep.
SECS_PER_RUN=84
TOTAL_SECS=$(( ${#SCENARIOS[@]} * 5 * N_RUNS * SECS_PER_RUN ))
TOTAL_H=$(( TOTAL_SECS / 3600 ))
TOTAL_M=$(( (TOTAL_SECS % 3600) / 60 ))

echo "================================================"
echo " Experiment 1 - Laptop B (Subscriber)"
echo " Scenarios : ${SCENARIOS[*]}"
echo " Conditions: baseline rp_hz rp_bag topic_hz rosbag2"
echo " Runs      : ${N_RUNS}"
echo " NIC      : ${NIC}"
if [[ -n "${SYNC_HOST}" ]]; then
  echo " Sync     : event-driven (A=${SYNC_HOST}, per-run publisher start/stop)"
else
  echo " Sync     : timer-based"
  echo " Estimate : ${TOTAL_H}h ${TOTAL_M}m"
fi
echo "================================================"
echo ""

trap cleanup EXIT
trap handle_signal INT TERM
start_sudo_keepalive
setup_env

normalize_tty
echo ""
echo "Pre-flight check:"
echo "  1) Start run_exp1_pub.sh --sync <B-wlan-IP> on Laptop A first"
echo ""
if [[ -n "${SYNC_HOST}" ]]; then
  echo "Event-driven sync mode: starting without an Enter prompt."
else
  read -rp "Press Enter when both laptops are ready..."
fi

START_TIME=$(date +%s)
FAILED=()
# Run rp conditions first to avoid DDS residue from ros2 tooling.
CONDITIONS=(baseline rp_hz rp_bag topic_hz rosbag2)

for SCENARIO in "${SCENARIOS[@]}"; do
  SCENARIO_START=$(date +%s)
  echo ""
  echo "================================================"
  echo " [$(date '+%H:%M:%S')] Scenario: ${SCENARIO}"
  echo "================================================"

  for CONDITION in "${CONDITIONS[@]}"; do
    echo ""
    echo "  -- ${SCENARIO} / ${CONDITION} ------------------"
    if ! sync_clock_for_condition "${SCENARIO}/${CONDITION}"; then
      echo "  [ERROR] clock sync failed; aborting experiment"
      exit 1
    fi
    for i in $(seq 1 "${N_RUNS}"); do
      RUN_LABEL="$(printf '%02d' ${i})/${N_RUNS}"
      echo "    run ${RUN_LABEL}  ($(date '+%H:%M:%S'))"
      setsid bash "${SCRIPT_DIR}/run_b.sh" "${SCENARIO}" "${CONDITION}" "${i}" &
      CURRENT_RUN_PID=$!
      if wait "${CURRENT_RUN_PID}"; then
        CURRENT_RUN_PID=""
      else
        RUN_STATUS=$?
        if [[ "${RUN_STATUS}" == "130" || "${RUN_STATUS}" == "143" ]]; then
          exit "${RUN_STATUS}"
        fi
        CURRENT_RUN_PID=""
        echo "    [WARN] run ${RUN_LABEL} failed; continuing"
        FAILED+=("${SCENARIO}/${CONDITION}/run$(printf '%02d' ${i})")
      fi
    done
    echo "  [ok] ${CONDITION} complete"
  done

  ELAPSED=$(( $(date +%s) - SCENARIO_START ))
  echo ""
  echo "  [ok] ${SCENARIO} complete - ${ELAPSED}s  ($(date '+%H:%M:%S'))"

  # Timer mode: wait before the next scenario unless this was the last one.
  if [[ -z "${SYNC_HOST}" && "${SCENARIO}" != "${SCENARIOS[-1]}" ]]; then
    SECS_PER_RUN_TIMER=80
    SCENARIO_WAIT=$(( 5 * N_RUNS * SECS_PER_RUN_TIMER + BUFFER_S ))
    REMAINING=$(( SCENARIO_WAIT - ELAPSED ))
    if (( REMAINING > 0 )); then
      echo "  Waiting ${REMAINING}s before the next scenario..."
      sleep "${REMAINING}"
    fi
  fi
done

# Event mode: notify Laptop A that the experiment is complete.
if [[ -n "${SYNC_HOST}" ]]; then
  echo "DONE" | nc -w5 "${SYNC_HOST}" "${SYNC_PORT}" 2>/dev/null || true
  echo "  [sync] DONE sent"
fi

# Final summary.
TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))
echo ""
echo "================================================"
echo " Experiment 1 complete  $(date '+%H:%M:%S')"
echo " Elapsed : $(( TOTAL_ELAPSED/3600 ))h $(( (TOTAL_ELAPSED%3600)/60 ))m"
echo " Results : ${REPO_DIR}/results/exp1/"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo " Failed runs (rerun required):"
  for f in "${FAILED[@]}"; do echo "   - ${f}"; done
fi
echo "================================================"
