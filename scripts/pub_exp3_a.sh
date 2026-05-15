#!/bin/bash
# Laptop A - Experiment 3 stress publisher runner
# usage: ./pub_exp3_a.sh <scenario>
# scenarios: ST100 | ST500 | ST1000

set -euo pipefail

normalize_tty() {
  [[ -t 1 ]] && stty sane opost onlcr 2>/dev/null || true
}

normalize_tty

SCENARIO=${1:?usage: $0 <scenario>}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

set +u
source /opt/ros/humble/setup.bash
source "${REPO_DIR}/install/setup.bash"
set -u

export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-77}

PAYLOAD_BYTES=${STRESS_PAYLOAD_BYTES:-65536}
TOPIC=${STRESS_TOPIC:-/stress}

case ${SCENARIO} in
  ST100)  HZ=100 ;;
  ST500)  HZ=500 ;;
  ST1000) HZ=1000 ;;
  *) echo "[ERROR] unknown scenario: ${SCENARIO}"; exit 1 ;;
esac

cleanup() {
  normalize_tty
  echo "[pub_exp3_a] stopped"
}

handle_signal() {
  trap - INT TERM
  normalize_tty
  exit 130
}

trap cleanup EXIT
trap handle_signal INT TERM

echo "[pub_exp3_a] starting ${SCENARIO}: ${HZ} Hz, payload=${PAYLOAD_BYTES}, topic=${TOPIC}"
ros2 run test stress_pub "${HZ}" "${PAYLOAD_BYTES}" 0 "${TOPIC}"
