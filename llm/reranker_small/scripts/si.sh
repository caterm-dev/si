#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

stage="${1:-}"
if [[ "$stage" != prepare && "$stage" != train && "$stage" != resume ]]; then
    printf 'Usage: %s {prepare|train|resume} [arguments]\n' "$0" >&2
    exit 2
fi
shift

experiment="${SI_RERANKER_SMALL_EXPERIMENT:-small-si-v3}"
config="${SI_RERANKER_SMALL_CONFIG:-$ri_root/configs/si.json}"
data="${SI_RERANKER_SMALL_DATA:-$ri_root/data/prepared/$experiment}"
run="${SI_RERANKER_SMALL_RUN:-$ri_root/runs/$experiment}"

if [[ "$stage" == prepare ]]; then
    ri_module llm.reranker_small.prepare --config "$config" --output "$data" \
        --parent-data "$ri_root/data/prepared/small-chat-v2" \
        --ancestor-data "$ri_root/data/prepared/small-character-v1" "$@"
fi

if [[ "$stage" == resume ]]; then
    initialization=(--resume)
else
    initialization=(--init-checkpoint "$ri_root/runs/small-chat-v2/best.pt")
fi
ri_module llm.reranker_small.train --config "$config" --data "$data" --run "$run" \
    --device "$ri_device" --threads "$ri_threads" "${initialization[@]}" "$@"
