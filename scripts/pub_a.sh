#!/bin/bash
# Laptop A - scenario publisher runner
# usage: ./pub_a.sh <scenario>
# e.g.:  ./pub_a.sh S3b
#
# Publishers run continuously. Stop them with Ctrl-C after the experiment.

set -euo pipefail

SCENARIO=${1:?usage: $0 <scenario>}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

set +u
source /opt/ros/humble/setup.bash
source "${REPO_DIR}/install/setup.bash"
set -u

export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ROS_DOMAIN_ID=77

cleanup() {
  echo "[pub_a] stopped"
}

handle_signal() {
  trap - INT TERM
  exit 130
}

trap cleanup EXIT
trap handle_signal INT TERM

echo "[pub_a] starting ${SCENARIO} publisher"

case ${SCENARIO} in
  S1)  ros2 run test s1_pub ;;
  S2)  ros2 run test s2_pub ;;
  S3a) ros2 run test s3a_pub ;;
  S3b) ros2 run test s3_points_pub 30000 ;;
  S3c) ros2 run test s3_points_pub 130000 ;;
  S4a) ros2 run test s4a_pub ;;
  S4b) ros2 run test s4_image_pub ;;
  S5a) ros2 launch test s5a_pub.launch.py ;;
  S5b) ros2 launch test s5b_pub.launch.py ;;
  *) echo "[ERROR] unknown scenario: ${SCENARIO}"; exit 1 ;;
esac
