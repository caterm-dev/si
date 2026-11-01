#!/bin/bash
# Versioned experiment paths only; no stage is automatically launched.
ri_experiment="${SI_RERANKER_SMALL_EXPERIMENT:-small-character-v1}"
ri_config="${SI_RERANKER_SMALL_CONFIG:-$ri_root/configs/small.json}"
ri_data="${SI_RERANKER_SMALL_DATA:-$ri_root/data/prepared/$ri_experiment}"
ri_run="${SI_RERANKER_SMALL_RUN:-$ri_root/runs/$ri_experiment}"
ri_reports="${SI_RERANKER_SMALL_REPORT_ROOT:-$ri_root/reports/$ri_experiment}"
ri_checkpoint="${SI_RERANKER_SMALL_CHECKPOINT:-$ri_run/best.pt}"
ri_export="${SI_RERANKER_SMALL_EXPORT:-$ri_root/exports/$ri_experiment}"
ri_device="${SI_RERANKER_SMALL_DEVICE:-mps}"
ri_threads="${SI_RERANKER_SMALL_THREADS:-4}"
