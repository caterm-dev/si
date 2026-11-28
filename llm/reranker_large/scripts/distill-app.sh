#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
rl_args=( \
  --config "$rl_root/configs/distill-app-v4.json" \
  --data "$rl_root/data/prepared/student-15m-v1/lm" \
  --pools "$rl_root/data/prepared/student-15m-v1/teacher-app-v4" \
  --run "$rl_root/runs/student-15m-extra-v1/distill-app-v4" )
if [[ "${1:-}" == --resume ]]; then
  shift
  rl_module resume --stage distill "${rl_args[@]}" "$@"
fi
rl_module distill "${rl_args[@]}" \
  --init-checkpoint "$rl_root/runs/student-15m-extra-v1/snapshots/continued-step-019167/best.pt" \
  --init-data "$rl_root/data/prepared/student-15m-extra-v1/lm" \
  "$@"
