#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
rl_module pools --config "${SI_RERANKER_LARGE_DISTILL_CONFIG:-$rl_root/configs/distill.json}" "$@"
