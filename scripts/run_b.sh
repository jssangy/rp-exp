#!/bin/bash
# Laptop B — single run
# usage: ./run_b.sh <scenario> <condition> <run>
# e.g.:  ./run_b.sh S3b rosbag2 1
#
# conditions: baseline | rp_hz | rp_bag | topic_hz | rosbag2
#
# 환경변수:
#   SYNC_HOST      : Laptop A wlan IP (설정 시 per-run pub 동기화)
#   SYNC_PORT      : B→A 포트 (기본 55001)
#   SYNC_ACK_PORT  : A→B 포트 (기본 55002)
#   NIC            : 측정 인터페이스 (미설정 시 자동 감지)

set -euo pipefail

# ROS 환경이 없으면 자동 소스
set +u
if ! command -v ros2 &>/dev/null; then
  source /opt/ros/humble/setup.bash
fi
SCRIPT_DIR_TMP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SETUP="$(dirname "${SCRIPT_DIR_TMP}")/install/setup.bash"
[[ -f "${INSTALL_SETUP}" ]] && source "${INSTALL_SETUP}"
set -u

export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-77}

SCENARIO=${1:?usage: $0 <scenario> <condition> <run>}
CONDITION=${2:?}
RUN=$(printf "%02d" "${3:?}")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
OUTDIR="${REPO_DIR}/results/exp1/${SCENARIO}/${CONDITION}/run${RUN}"
BAGDIR="${REPO_DIR}/bags/exp1/${SCENARIO}/${CONDITION}/run${RUN}"

NIC=${NIC:-$(ip route show default | awk '/default/ {print $5; exit}')}
SYNC_HOST=${SYNC_HOST:-""}
SYNC_PORT=${SYNC_PORT:-55001}
SYNC_ACK_PORT=${SYNC_ACK_PORT:-55002}

CLK_TCK=$(getconf CLK_TCK)

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

if [[ ${SCENARIO} == S5* ]]; then
  BAG_TOPICS="--all"
else
  BAG_TOPICS="${TOPIC}"
fi

mkdir -p "${OUTDIR}"
echo "[run_b] ${SCENARIO}/${CONDITION}/run${RUN}  NIC=${NIC}  outdir=${OUTDIR}"

# ros2 daemon 잔재 제거
ros2 daemon stop 2>/dev/null || true

# ── Step 1: observer 도구 먼저 실행 (DDS discovery 전에 프로빙 시작) ──────────
OBS_PID=""
RP_PID=""

case ${CONDITION} in
  topic_hz)
    ros2 topic hz "${TOPIC}" > "${OUTDIR}/obs.log" 2>&1 &
    OBS_PID=$!
    ;;
  rosbag2)
    mkdir -p "${BAGDIR}"
    ros2 bag record ${BAG_TOPICS} --storage mcap -o "${BAGDIR}/rosbag2" > "${OUTDIR}/obs.log" 2>&1 &
    OBS_PID=$!
    ;;
  rp_hz)
    sudo rp run > "${OUTDIR}/obs.log" 2>&1 &
    RP_PID=$!
    sleep 1  # rp run이 소켓을 열 때까지 대기
    rp topic hz "${TOPIC}" >> "${OUTDIR}/obs.log" 2>&1 &
    OBS_PID=$!
    ;;
  rp_bag)
    mkdir -p "${BAGDIR}"
    sudo rp run > "${OUTDIR}/obs.log" 2>&1 &
    RP_PID=$!
    sleep 1  # rp run이 소켓을 열 때까지 대기
    rp bag record ${BAG_TOPICS} -o "${BAGDIR}/rp" >> "${OUTDIR}/obs.log" 2>&1 &
    OBS_PID=$!
    ;;
  baseline)
    ;;
  *)
    echo "[ERROR] unknown condition: ${CONDITION}"; exit 1
    ;;
esac

# ── Step 2: Laptop A에 publisher 시작 요청 ────────────────────────────────────
if [[ -n "${SYNC_HOST}" ]]; then
  echo "  [sync] START ${SCENARIO} 전송..."
  echo "START ${SCENARIO}" | nc -w5 "${SYNC_HOST}" "${SYNC_PORT}" 2>/dev/null || true
  nc -l -w30 -p "${SYNC_ACK_PORT}" > /dev/null 2>&1 || true
  echo "  [sync] Publisher 준비 완료  $(date '+%H:%M:%S')"
else
  echo "  [warn] SYNC_HOST 미설정 — publisher가 이미 실행 중이어야 함"
fi

# ── Step 3: subscriber 백그라운드 실행 (10s warmup 내장) ──────────────────────
ros2 run test "${SUB_NODE}" > "${OUTDIR}/sub.log" &
SUB_PID=$!

# ── Step 4: warmup 대기 후 netdev + CPU/메모리 샘플링 시작 ───────────────────
sleep 10

# /proc/net/dev 샘플링
(
  while true; do
    grep " ${NIC}:" /proc/net/dev \
      | awk -v t="$(date +%s%3N)" '{print t, $2}'
    sleep 1
  done
) > "${OUTDIR}/netdev.log" &
NETDEV_PID=$!

# 시스템 전체 CPU/메모리 샘플링 (모든 조건에서 실행)
# 출력: timestamp_ms  cpu%  used_kb
# CPU%: /proc/stat idle 델타 기반, 메모리: /proc/meminfo MemTotal-MemAvailable
(
  set +e
  prev=$(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
  prev_total=$(echo "${prev}" | awk '{print $1}')
  prev_idle=$(echo "${prev}"  | awk '{print $2}')

  while true; do
    sleep 1
    curr_t=$(date +%s%3N)
    curr=$(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
    curr_total=$(echo "${curr}" | awk '{print $1}')
    curr_idle=$(echo "${curr}"  | awk '{print $2}')
    delta_total=$(( curr_total - prev_total ))
    delta_idle=$(( curr_idle  - prev_idle  ))
    [[ ${delta_total} -le 0 ]] && delta_total=1
    cpu_pct=$(awk "BEGIN {printf \"%.1f\", (1 - ${delta_idle}/${delta_total}) * 100}")
    used_kb=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print t-a}' /proc/meminfo)
    echo "${curr_t} ${cpu_pct} ${used_kb}"
    prev_total=${curr_total}
    prev_idle=${curr_idle}
  done
) > "${OUTDIR}/cpu_mem.log" &
CPU_MEM_PID=$!

# ── Step 5: subscriber 종료 대기 (60s 측정 후 자동 종료) ──────────────────────
wait "${SUB_PID}" 2>/dev/null || true
echo "  [sub] 완료  $(date '+%H:%M:%S')"

# ── Step 6: Laptop A에 publisher 종료 요청 ───────────────────────────────────
if [[ -n "${SYNC_HOST}" ]]; then
  echo "STOP" | nc -w5 "${SYNC_HOST}" "${SYNC_PORT}" 2>/dev/null || true
fi

# ── Step 7: 백그라운드 프로세스 정리 ─────────────────────────────────────────
[[ -n "${OBS_PID}"     ]] && kill "${OBS_PID}"     2>/dev/null || true
[[ -n "${RP_PID}"      ]] && kill "${RP_PID}"       2>/dev/null || true
[[ -n "${CPU_MEM_PID}" ]] && kill "${CPU_MEM_PID}"  2>/dev/null || true
kill "${NETDEV_PID}" 2>/dev/null || true
wait 2>/dev/null || true

# ── Step 8: 잔존 ROS 2 프로세스 전체 강제 종료 ────────────────────────────────
pkill -SIGTERM -f "ros2 run"    2>/dev/null || true
pkill -SIGTERM -f "ros2 launch" 2>/dev/null || true
pkill -SIGTERM -f "ros2 topic"  2>/dev/null || true
pkill -SIGTERM -f "ros2 bag"    2>/dev/null || true
pkill -SIGTERM -f "rp topic"    2>/dev/null || true
pkill -SIGTERM -f "rp bag"      2>/dev/null || true
[[ -n "${RP_PID}" ]] && sudo pkill -SIGTERM -f "rp run" 2>/dev/null || true
sleep 2
pkill -SIGKILL -f "ros2 run"    2>/dev/null || true
pkill -SIGKILL -f "ros2 launch" 2>/dev/null || true
pkill -SIGKILL -f "ros2 topic"  2>/dev/null || true
pkill -SIGKILL -f "ros2 bag"    2>/dev/null || true
pkill -SIGKILL -f "rp topic"    2>/dev/null || true
pkill -SIGKILL -f "rp bag"      2>/dev/null || true
[[ -n "${RP_PID}" ]] && sudo pkill -SIGKILL -f "rp run" 2>/dev/null || true
ros2 daemon stop 2>/dev/null || true

echo "[run_b] run${RUN} done → ${OUTDIR}"
sleep 10
