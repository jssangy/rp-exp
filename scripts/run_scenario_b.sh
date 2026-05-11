#!/bin/bash
# Laptop B — 한 시나리오 전체 실행 (5 conditions × 10 runs)
# usage: ./run_scenario_b.sh <scenario> [runs]
# e.g.:  ./run_scenario_b.sh S3b
#        ./run_scenario_b.sh S3b 3   # 테스트용 3회만

set -euo pipefail

SCENARIO=${1:?usage: $0 <scenario> [runs]}
N_RUNS=${2:-10}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONDITIONS=(baseline topic_hz rosbag2 rp_hz rp_bag)

echo "========================================"
echo "Scenario : ${SCENARIO}"
echo "Runs/cond: ${N_RUNS}"
echo "Conditions: ${CONDITIONS[*]}"
echo "========================================"
echo "Laptop A에서 publisher를 먼저 실행하세요:"
echo "  ./scripts/pub_a.sh ${SCENARIO}"
echo ""
read -rp "publisher 실행 확인 후 Enter..."

for CONDITION in "${CONDITIONS[@]}"; do
  echo ""
  echo "──── ${SCENARIO} / ${CONDITION} ────────────────────"
  for i in $(seq 1 "${N_RUNS}"); do
    echo "  run $(printf '%02d' ${i})/${N_RUNS}"
    bash "${SCRIPT_DIR}/run_b.sh" "${SCENARIO}" "${CONDITION}" "${i}"
  done
  echo "  ✓ ${CONDITION} complete"
done

echo ""
echo "========================================"
echo "Scenario ${SCENARIO} 완료"
echo "결과: results/exp1/${SCENARIO}/"
echo "========================================"
