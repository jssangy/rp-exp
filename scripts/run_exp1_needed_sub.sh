#!/bin/bash
# Laptop B - targeted rerun plan for the current Experiment 1 fixes.
#
# Runs only:
#   - S1/S2/S3a/S3b/S3c/S4a/S4b rosbag2
#   - S5a all conditions
#   - S5b all conditions
#
# Usage:
#   ./scripts/run_exp1_needed_sub.sh --sync <Laptop-A-IP> --clean-targets
#
# Start Laptop A first:
#   ./scripts/run_exp1_pub.sh --sync <Laptop-B-IP>

set -euo pipefail

normalize_tty() {
  [[ -t 1 ]] && stty sane opost onlcr 2>/dev/null || true
}

normalize_tty

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

N_RUNS=10
START_RUN=1
END_RUN=10
SYNC_HOST=""
SYNC_PORT=55001
SYNC_ACK_PORT=55002
CLEAN_TARGETS=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --runs)          N_RUNS="$2"; END_RUN="$2"; shift 2 ;;
    --start-run)     START_RUN="$2"; shift 2 ;;
    --end-run)       END_RUN="$2"; shift 2 ;;
    --sync)          SYNC_HOST="$2"; shift 2 ;;
    --sync-port)     SYNC_PORT="$2"; shift 2 ;;
    --sync-ack-port) SYNC_ACK_PORT="$2"; shift 2 ;;
    --clean-targets) CLEAN_TARGETS=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    *)
      echo "[ERROR] unknown option: $1"
      echo "usage: $0 --sync <Laptop-A-IP> [--clean-targets] [--runs N] [--start-run N --end-run N] [--dry-run]"
      exit 1
      ;;
  esac
done

if (( START_RUN < 1 || END_RUN < START_RUN || END_RUN > N_RUNS )); then
  echo "[ERROR] invalid run range: start=${START_RUN}, end=${END_RUN}, runs=${N_RUNS}" >&2
  exit 1
fi

set +u
if ! command -v ros2 &>/dev/null; then
  source /opt/ros/humble/setup.bash
fi
source "${REPO_DIR}/install/setup.bash"
set -u

export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-77}
export NIC=${NIC:-$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')}
export SYNC_HOST
export SYNC_PORT
export SYNC_ACK_PORT

SUDO_KEEPALIVE_PID=""
CURRENT_RUN_PID=""
CLEANED_UP=0

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
  echo "[interrupt] targeted rerun stop requested"
  exit 130
}

conditions_for_scenario() {
  case "$1" in
    S1|S2|S3a|S3b|S3c|S4a|S4b)
      echo "rosbag2"
      ;;
    S5a|S5b)
      echo "baseline rp_hz rp_bag topic_hz rosbag2"
      ;;
    *)
      echo "[ERROR] unknown scenario in rerun plan: $1" >&2
      return 1
      ;;
  esac
}

clean_target() {
  local scenario=${1:?}
  local condition=${2:?}
  local run_no=${3:?}
  local run_dir

  run_dir="$(printf 'run%02d' "${run_no}")"
  rm -rf \
    "${REPO_DIR}/results/exp1/${scenario}/${condition}/${run_dir}" \
    "${REPO_DIR}/bags/exp1/${scenario}/${condition}/${run_dir}"
}

trap cleanup EXIT
trap handle_signal INT TERM

SCENARIOS=(S1 S2 S3a S3b S3c S4a S4b S5a S5b)
TOTAL_RUNS=0
for scenario in "${SCENARIOS[@]}"; do
  read -r -a conds <<< "$(conditions_for_scenario "${scenario}")"
  TOTAL_RUNS=$(( TOTAL_RUNS + ${#conds[@]} * (END_RUN - START_RUN + 1) ))
done

SECS_PER_RUN=84
TOTAL_SECS=$(( TOTAL_RUNS * SECS_PER_RUN ))

echo "================================================"
echo " Experiment 1 - targeted rerun plan (Laptop B)"
echo " Plan      : S1-S4 rosbag2; S5a/S5b all conditions"
echo " Runs      : ${START_RUN}..${END_RUN} of ${N_RUNS}"
echo " Total     : ${TOTAL_RUNS} runs"
echo " Estimate  : $(( TOTAL_SECS / 3600 ))h $(( (TOTAL_SECS % 3600) / 60 ))m"
echo " NIC       : ${NIC}"
if [[ -n "${SYNC_HOST}" ]]; then
  echo " Sync      : event-driven (A=${SYNC_HOST})"
else
  echo " Sync      : disabled; publisher must already be running per scenario"
fi
echo " Clean     : ${CLEAN_TARGETS}"
echo " Dry run   : ${DRY_RUN}"
echo "================================================"
echo ""

if [[ "${DRY_RUN}" == "1" ]]; then
  for scenario in "${SCENARIOS[@]}"; do
    read -r -a conds <<< "$(conditions_for_scenario "${scenario}")"
    for condition in "${conds[@]}"; do
      for run_no in $(seq "${START_RUN}" "${END_RUN}"); do
        printf '%s/%s/run%02d\n' "${scenario}" "${condition}" "${run_no}"
      done
    done
  done
  exit 0
fi

start_sudo_keepalive
setup_env

if [[ -n "${SYNC_HOST}" ]]; then
  echo "Event-driven sync mode: start run_exp1_pub.sh --sync <B-IP> on Laptop A first."
else
  read -rp "Press Enter when the matching publisher is ready..."
fi

START_TIME=$(date +%s)
FAILED=()

for scenario in "${SCENARIOS[@]}"; do
  read -r -a conds <<< "$(conditions_for_scenario "${scenario}")"

  echo ""
  echo "================================================"
  echo " [$(date '+%H:%M:%S')] Scenario: ${scenario}"
  echo " Conditions: ${conds[*]}"
  echo "================================================"

  for condition in "${conds[@]}"; do
    echo ""
    echo "  -- ${scenario} / ${condition} ------------------"
    for run_no in $(seq "${START_RUN}" "${END_RUN}"); do
      run_label="$(printf '%02d' "${run_no}")/${N_RUNS}"
      echo "    run ${run_label}  ($(date '+%H:%M:%S'))"
      if [[ "${CLEAN_TARGETS}" == "1" ]]; then
        clean_target "${scenario}" "${condition}" "${run_no}"
      fi
      setsid bash "${SCRIPT_DIR}/run_b.sh" "${scenario}" "${condition}" "${run_no}" &
      CURRENT_RUN_PID=$!
      if wait "${CURRENT_RUN_PID}"; then
        CURRENT_RUN_PID=""
      else
        status=$?
        if [[ "${status}" == "130" || "${status}" == "143" ]]; then
          exit "${status}"
        fi
        CURRENT_RUN_PID=""
        echo "    [WARN] run ${run_label} failed; continuing"
        FAILED+=("${scenario}/${condition}/run$(printf '%02d' "${run_no}")")
      fi
    done
    echo "  [ok] ${condition} complete"
  done
done

if [[ -n "${SYNC_HOST}" ]]; then
  echo "DONE" | nc -w5 "${SYNC_HOST}" "${SYNC_PORT}" 2>/dev/null || true
  echo "  [sync] DONE sent"
fi

TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))
echo ""
echo "================================================"
echo " Targeted rerun complete  $(date '+%H:%M:%S')"
echo " Elapsed : $(( TOTAL_ELAPSED / 3600 ))h $(( (TOTAL_ELAPSED % 3600) / 60 ))m"
echo " Results : ${REPO_DIR}/results/exp1/"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo " Failed runs:"
  for f in "${FAILED[@]}"; do echo "   - ${f}"; done
fi
echo "================================================"
