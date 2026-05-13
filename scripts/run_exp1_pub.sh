#!/bin/bash
# Laptop A - Experiment 1 publisher controller
#
# Usage:
#   ./scripts/run_exp1_pub.sh --sync <Laptop-B-IP>   # event-driven mode
#   ./scripts/run_exp1_pub.sh                        # timer-based legacy mode
#
# Event mode (--sync):
#   B sends "START <scenario>" / "STOP" / "DONE" for each run.
#   A starts/stops publishers accordingly.
#   B -> A: port 55001 / A -> B: port 55002
#
# Timer mode:
#   Keep publishers alive for SCENARIO_WAIT per scenario when --sync is not used.

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
source /opt/ros/humble/setup.bash
source "${REPO_DIR}/install/setup.bash"
set -u
export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-77}

SUDO_KEEPALIVE_PID=""
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

# Environment setup.
setup_env() {
  echo "[setup] CPU governor -> performance"
  sudo cpupower frequency-set -g performance 2>/dev/null \
    || echo "  [warn] cpupower failed; continuing"
}

# Publisher control.

PUB_PID=""

stop_current() {
  if [[ -n "${PUB_PID}" ]]; then
    echo "[pub] stopping (PID ${PUB_PID})  $(date '+%H:%M:%S')"
    # Kill the whole process group started by setsid.
    kill -SIGTERM -- "-${PUB_PID}" 2>/dev/null || true
    sleep 1
    kill -SIGKILL -- "-${PUB_PID}" 2>/dev/null || true
    wait "${PUB_PID}" 2>/dev/null || true
    PUB_PID=""
  fi
}
cleanup() {
  [[ "${CLEANED_UP}" == "1" ]] && return
  CLEANED_UP=1
  normalize_tty
  stop_current
  stop_sudo_keepalive
}

handle_signal() {
  trap - INT TERM
  normalize_tty
  echo ""
  echo "[interrupt] stop requested; cleaning up..."
  exit 130
}

trap cleanup EXIT
trap handle_signal INT TERM

# Event-driven mode.

run_event_driven() {
  echo "================================================"
  echo " Experiment 1 - Laptop A (Publisher, event-driven)"
  echo " B wlan IP : ${SYNC_HOST}"
  echo " Listen port: ${SYNC_PORT}  ACK port: ${SYNC_ACK_PORT}"
  echo "================================================"
  echo ""

  start_sudo_keepalive
  setup_env

  normalize_tty
  echo ""
  echo " Waiting for commands from Laptop B. Start run_exp1_sub.sh --sync <A-IP> on Laptop B."
  echo ""

  while true; do
    CMD=$(nc -l -p "${SYNC_PORT}" 2>/dev/null || true)
    CMD="${CMD%%$'\r'}"  # Strip carriage return.

    case "${CMD}" in
      START\ *)
        SCENARIO="${CMD#START }"
        stop_current
        echo ""
        echo "  [$(date '+%H:%M:%S')] starting ${SCENARIO} publisher"
        setsid bash "${SCRIPT_DIR}/pub_a.sh" "${SCENARIO}" &
        PUB_PID=$!
        sleep 1  # Wait for publisher initialization.
        echo "READY" | nc -w5 "${SYNC_HOST}" "${SYNC_ACK_PORT}" 2>/dev/null || true
        ;;
      STOP)
        echo "  [$(date '+%H:%M:%S')] publisher stop requested"
        stop_current
        ;;
      DONE)
        echo ""
        echo "================================================"
        echo " Experiment 1 (Laptop A) complete  $(date '+%H:%M:%S')"
        echo "================================================"
        break
        ;;
      "")
        ;;
      *)
        echo "[WARN] unknown command: '${CMD}'"
        ;;
    esac
  done
}

# Timer-based legacy mode.

run_timer_based() {
  SECS_PER_RUN=80
  SCENARIO_WAIT=$(( 5 * N_RUNS * SECS_PER_RUN + BUFFER_S ))
  TOTAL_SECS=$(( ${#SCENARIOS[@]} * SCENARIO_WAIT ))
  TOTAL_H=$(( TOTAL_SECS / 3600 ))
  TOTAL_M=$(( (TOTAL_SECS % 3600) / 60 ))

  echo "================================================"
  echo " Experiment 1 - Laptop A (Publisher, timer-based)"
  echo " Scenarios       : ${SCENARIOS[*]}"
  echo " Runs            : ${N_RUNS}"
  echo " Per scenario    : ${SCENARIO_WAIT}s"
  echo " Estimate        : ${TOTAL_H}h ${TOTAL_M}m"
  echo "================================================"
  echo ""

  start_sudo_keepalive
  setup_env

  normalize_tty
  echo ""
  echo " Start run_exp1_sub.sh on Laptop B."
  echo " Press Enter on both laptops at the same time."
  echo ""
  read -rp "Press Enter when ready..."

  for SCENARIO in "${SCENARIOS[@]}"; do
    echo ""
    echo "========================================"
    echo " [$(date '+%H:%M:%S')] Scenario: ${SCENARIO}"
    echo "========================================"

    setsid bash "${SCRIPT_DIR}/pub_a.sh" "${SCENARIO}" &
    PUB_PID=$!
    echo "[pub] started (PID ${PUB_PID})"

    END_TS=$(( $(date +%s) + SCENARIO_WAIT ))
    while (( $(date +%s) < END_TS )); do
      REMAINING=$(( END_TS - $(date +%s) ))
      echo "  Waiting... ${REMAINING}s remaining"
      sleep 5
    done

    stop_current
    echo "[pub] ${SCENARIO} complete  $(date '+%H:%M:%S')"
  done

  echo ""
  echo "================================================"
  echo " Experiment 1 (Laptop A) complete  $(date '+%H:%M:%S')"
  echo "================================================"
}

# Main.

if [[ -n "${SYNC_HOST}" ]]; then
  run_event_driven
else
  run_timer_based
fi
