#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
rl_module distill \
  --config "$rl_root/configs/distill-pilot.json" \
  --data "$rl_root/data/prepared/student-15m-v1/lm" \
  --pools "$rl_root/data/prepared/student-15m-v1/teacher-pilot" \
  --run "$rl_root/runs/student-15m-extra-v1/distill-pilot" \
  --init-checkpoint "$rl_root/runs/student-15m-extra-v1/snapshots/continued-step-019167/best.pt" \
  --init-data "$rl_root/data/prepared/student-15m-extra-v1/lm" \
  "$@"
