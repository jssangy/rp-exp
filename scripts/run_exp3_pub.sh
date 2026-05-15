#!/bin/bash
# Laptop A - Experiment 3 publisher controller
#
# Usage:
#   ./scripts/run_exp3_pub.sh --sync <Receiver-IP>
#
# B sends "START <scenario>" / "STOP" / "DONE" for each run.
# B -> A: port 56001 / A -> B: port 56002

set -euo pipefail

normalize_tty() {
  [[ -t 1 ]] && stty sane opost onlcr 2>/dev/null || true
}

normalize_tty

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

SYNC_HOST=""
SYNC_PORT=56001
SYNC_ACK_PORT=56002

while [[ $# -gt 0 ]]; do
  case $1 in
    --sync) SYNC_HOST="$2"; shift 2 ;;
    --port) SYNC_PORT="$2"; shift 2 ;;
    --ack-port) SYNC_ACK_PORT="$2"; shift 2 ;;
    *) echo "[ERROR] unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "${SYNC_HOST}" ]]; then
  echo "[ERROR] --sync <Receiver-IP> is required"
  exit 1
fi

set +u
source /opt/ros/humble/setup.bash
source "${REPO_DIR}/install/setup.bash"
set -u

export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-79}

SUDO_KEEPALIVE_PID=""
PUB_PID=""
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

setup_env() {
  echo "[setup] CPU governor -> performance"
  sudo cpupower frequency-set -g performance 2>/dev/null \
    || echo "  [warn] cpupower failed; continuing"
}

stop_current() {
  if [[ -n "${PUB_PID}" ]]; then
    echo "[pub] stopping (PID ${PUB_PID})  $(date '+%H:%M:%S')"
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
  cleanup
  exit 130
}

trap cleanup EXIT
trap handle_signal INT TERM

echo "================================================"
echo " Experiment 3 - Publisher Host"
echo " Receiver IP : ${SYNC_HOST}"
echo " Listen port : ${SYNC_PORT}"
echo " ACK port    : ${SYNC_ACK_PORT}"
echo " ROS_DOMAIN  : ${ROS_DOMAIN_ID}"
echo "================================================"
echo ""

start_sudo_keepalive
setup_env

echo "Waiting for commands from Receiver. Start run_exp3_sub.sh --sync <Publisher-IP> on receiver."
echo ""

while true; do
  CMD=$(nc -l -p "${SYNC_PORT}" 2>/dev/null || true)
  CMD="${CMD%%$'\r'}"

  case "${CMD}" in
    START\ *)
      SCENARIO="${CMD#START }"
      stop_current
      echo ""
      echo "  [$(date '+%H:%M:%S')] starting ${SCENARIO} publisher"
      setsid bash "${SCRIPT_DIR}/pub_exp3_a.sh" "${SCENARIO}" &
      PUB_PID=$!
      sleep 1
      echo "READY" | nc -w5 "${SYNC_HOST}" "${SYNC_ACK_PORT}" 2>/dev/null || true
      ;;
    STOP)
      echo "  [$(date '+%H:%M:%S')] publisher stop requested"
      stop_current
      ;;
    DONE)
      echo ""
      echo "================================================"
      echo " Experiment 3 publisher complete  $(date '+%H:%M:%S')"
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
