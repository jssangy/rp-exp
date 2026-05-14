#!/bin/bash
# Laptop B - Experiment 1 targeted rerun runner
#
# Usage:
#   ./scripts/run_exp1_needed_sub.sh --sync <Laptop-A-IP> --clean-targets
#
# Event mode: send START/STOP to Laptop A for every run.
#
# Rerun plan:
#   S1-S4: rosbag2 only
#   S5a  : baseline rp_hz rp_bag topic_hz rosbag2
#   S5b  : baseline rp_hz rp_bag topic_hz rosbag2

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
SYNC_HOST=""
SYNC_PORT=55001
SYNC_ACK_PORT=55002
CLEAN_TARGETS=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --scenarios)     IFS=',' read -ra SCENARIOS <<< "$2"; shift 2 ;;
    --runs)          N_RUNS="$2"; shift 2 ;;
    --sync)          SYNC_HOST="$2"; shift 2 ;;
    --clean-targets) CLEAN_TARGETS=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
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

NIC=${NIC:-$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)}
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

# Environment setup.
setup_env() {
  echo "[setup] CPU governor -> performance"
  sudo cpupower frequency-set -g performance 2>/dev/null \
    || echo "  [warn] cpupower failed; continuing"
}

cleanup() {
  [[ "${CLEANED_UP}" == "1" ]] && return
  CLEANED_UP=1
  normalize_tty
  stop_current_run
  stop_sudo_keepalive
}

handle_signal() {
  trap - INT TERM
  normalize_tty
  echo ""
  echo "[interrupt] stop requested; cleaning up..."
  exit 130
}

conditions_for_scenario() {
  case $1 in
    S1|S2|S3a|S3b|S3c|S4a|S4b) echo "rosbag2" ;;
    S5a|S5b) echo "baseline rp_hz rp_bag topic_hz rosbag2" ;;
    *) echo "[ERROR] unknown scenario: $1" >&2; return 1 ;;
  esac
}

clean_target() {
  local scenario=${1:?}
  local condition=${2:?}
  local run=${3:?}
  local run_dir

  run_dir="$(printf 'run%02d' "${run}")"
  rm -rf \
    "${REPO_DIR}/results/exp1/${scenario}/${condition}/${run_dir}" \
    "${REPO_DIR}/bags/exp1/${scenario}/${condition}/${run_dir}"
}

TOTAL_RUNS=0
for SCENARIO in "${SCENARIOS[@]}"; do
  read -r -a SCENARIO_CONDITIONS <<< "$(conditions_for_scenario "${SCENARIO}")"
  TOTAL_RUNS=$(( TOTAL_RUNS + ${#SCENARIO_CONDITIONS[@]} * N_RUNS ))
done

# Time estimate per run: 2s pub ready + 10s warmup + 60s measure + 2s stop + 10s sleep.
SECS_PER_RUN=84
TOTAL_SECS=$(( TOTAL_RUNS * SECS_PER_RUN ))
TOTAL_H=$(( TOTAL_SECS / 3600 ))
TOTAL_M=$(( (TOTAL_SECS % 3600) / 60 ))

echo "================================================"
echo " Experiment 1 - Laptop B (Targeted Rerun)"
echo " Scenarios : ${SCENARIOS[*]}"
echo " Plan      : S1-S4 rosbag2; S5a/S5b all conditions"
echo " Runs      : ${N_RUNS}"
echo " Total     : ${TOTAL_RUNS}"
echo " NIC      : ${NIC}"
if [[ -n "${SYNC_HOST}" ]]; then
  echo " Sync     : event-driven (A=${SYNC_HOST}, per-run publisher start/stop)"
else
  echo " Sync     : timer-based"
fi
echo " Clean    : ${CLEAN_TARGETS}"
echo " Estimate : ${TOTAL_H}h ${TOTAL_M}m"
echo "================================================"
echo ""

if [[ "${DRY_RUN}" == "1" ]]; then
  for SCENARIO in "${SCENARIOS[@]}"; do
    read -r -a SCENARIO_CONDITIONS <<< "$(conditions_for_scenario "${SCENARIO}")"
    for CONDITION in "${SCENARIO_CONDITIONS[@]}"; do
      for i in $(seq 1 "${N_RUNS}"); do
        printf '%s/%s/run%02d\n' "${SCENARIO}" "${CONDITION}" "${i}"
      done
    done
  done
  exit 0
fi

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

for SCENARIO in "${SCENARIOS[@]}"; do
  SCENARIO_START=$(date +%s)
  read -r -a SCENARIO_CONDITIONS <<< "$(conditions_for_scenario "${SCENARIO}")"
  echo ""
  echo "================================================"
  echo " [$(date '+%H:%M:%S')] Scenario: ${SCENARIO}"
  echo "================================================"

  for CONDITION in "${SCENARIO_CONDITIONS[@]}"; do
    echo ""
    echo "  -- ${SCENARIO} / ${CONDITION} ------------------"
    for i in $(seq 1 "${N_RUNS}"); do
      RUN_LABEL="$(printf '%02d' ${i})/${N_RUNS}"
      echo "    run ${RUN_LABEL}  ($(date '+%H:%M:%S'))"
      if [[ "${CLEAN_TARGETS}" == "1" ]]; then
        clean_target "${SCENARIO}" "${CONDITION}" "${i}"
      fi
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
echo " Experiment 1 targeted rerun complete  $(date '+%H:%M:%S')"
echo " Elapsed : $(( TOTAL_ELAPSED/3600 ))h $(( (TOTAL_ELAPSED%3600)/60 ))m"
echo " Results : ${REPO_DIR}/results/exp1/"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo " Failed runs (rerun required):"
  for f in "${FAILED[@]}"; do echo "   - ${f}"; done
fi
echo "================================================"
