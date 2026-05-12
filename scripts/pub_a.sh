#!/bin/bash
# Laptop A — 시나리오별 publisher 실행
# usage: ./pub_a.sh <scenario>
# e.g.:  ./pub_a.sh S3b
#
# publisher는 무한 루프 (S5는 300s). 실험 완료 후 Ctrl-C로 종료.

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

# 종료 시 test 패키지 pub 노드 전체 정리 (launch 하위 프로세스 포함)
cleanup() {
  echo "[pub_a] 정리 중..."
  pkill -f "ros2 run test .*pub" 2>/dev/null || true
  pkill -f "ros2 launch test .*pub" 2>/dev/null || true
  sleep 1
}
trap cleanup EXIT TERM INT

echo "[pub_a] ${SCENARIO} publisher 시작"

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
