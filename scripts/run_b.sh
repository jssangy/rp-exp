#!/bin/bash
# Laptop B — single run
# usage: ./run_b.sh <scenario> <condition> <run>
# e.g.:  ./run_b.sh S3b rosbag2 1
#
# conditions: baseline | topic_hz | rosbag2 | rp_hz | rp_bag

set -euo pipefail

# ROS 환경이 없으면 자동 소스
if ! command -v ros2 &>/dev/null; then
  source /opt/ros/humble/setup.bash
fi
SCRIPT_DIR_TMP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SETUP="$(dirname "${SCRIPT_DIR_TMP}")/install/setup.bash"
[[ -f "${INSTALL_SETUP}" ]] && source "${INSTALL_SETUP}"

export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-77}

SCENARIO=${1:?usage: $0 <scenario> <condition> <run>}
CONDITION=${2:?}
RUN=$(printf "%02d" "${3:?}")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
OUTDIR="${REPO_DIR}/results/exp1/${SCENARIO}/${CONDITION}/run${RUN}"

# NIC 인터페이스 (기본: 기본 게이트웨이 인터페이스 자동 감지)
NIC=${NIC:-$(ip route show default | awk '/default/ {print $5; exit}')}

# 시나리오별 설정
case ${SCENARIO} in
  S1)  SUB_NODE="s1_sub";        TOPIC="/cmd_vel" ;;
  S2)  SUB_NODE="s2_sub";        TOPIC="/imu" ;;
  S3a) SUB_NODE="s3a_sub";       TOPIC="/scan" ;;
  S3b) SUB_NODE="s3_points_sub"; TOPIC="/points" ;;
  S3c) SUB_NODE="s3_points_sub"; TOPIC="/points" ;;
  S4a) SUB_NODE="s4a_sub";       TOPIC="/image_raw/compressed" ;;
  S4b) SUB_NODE="s4_image_sub";  TOPIC="/depth/image_raw" ;;
  S5a) SUB_NODE="s5a_sub";       TOPIC="/image_raw/compressed" ;;
  S5b) SUB_NODE="s5b_sub";       TOPIC="/points" ;;
  *) echo "[ERROR] unknown scenario: ${SCENARIO}"; exit 1 ;;
esac

# S5는 bag 조건에서 --all 사용
if [[ ${SCENARIO} == S5* ]]; then
  BAG_TOPICS="--all"
else
  BAG_TOPICS="${TOPIC}"
fi

mkdir -p "${OUTDIR}"
echo "[run_b] ${SCENARIO}/${CONDITION}/run${RUN}  NIC=${NIC}  outdir=${OUTDIR}"

# ── Step 3: observer 도구 (baseline은 skip) ─────────────────────────────────
OBS_PID=""
case ${CONDITION} in
  topic_hz)
    ros2 topic hz "${TOPIC}" > "${OUTDIR}/obs.log" 2>&1 &
    OBS_PID=$!
    ;;
  rosbag2)
    ros2 bag record ${BAG_TOPICS} -o "${OUTDIR}/bag" > "${OUTDIR}/obs.log" 2>&1 &
    OBS_PID=$!
    ;;
  rp_hz)
    rp topic hz "${TOPIC}" > "${OUTDIR}/obs.log" 2>&1 &
    OBS_PID=$!
    ;;
  rp_bag)
    rp bag record ${BAG_TOPICS} -o "${OUTDIR}/bag" > "${OUTDIR}/obs.log" 2>&1 &
    OBS_PID=$!
    ;;
  baseline)
    ;;
  *)
    echo "[ERROR] unknown condition: ${CONDITION}"; exit 1
    ;;
esac

# ── Step 5: /proc/net/dev 샘플링 ─────────────────────────────────────────────
(
  while true; do
    grep " ${NIC}:" /proc/net/dev \
      | awk -v t="$(date +%s%3N)" '{print t, $2, $10}'
    sleep 1
  done
) > "${OUTDIR}/netdev.log" &
NETDEV_PID=$!

# ── Step 6: subscriber (10s warmup + 60s measure 후 자동 종료) ───────────────
ros2 run test "${SUB_NODE}" 2>&1 | tee "${OUTDIR}/sub.log"

# ── Step 8: 정리 ─────────────────────────────────────────────────────────────
[[ -n "${OBS_PID}" ]] && kill "${OBS_PID}" 2>/dev/null || true
kill "${NETDEV_PID}" 2>/dev/null || true
wait 2>/dev/null || true

echo "[run_b] run${RUN} done → ${OUTDIR}"
sleep 10
