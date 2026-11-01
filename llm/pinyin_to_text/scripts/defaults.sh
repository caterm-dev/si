#!/bin/bash
# Shared presets only; sourcing this file never runs another stage.
# Change the experiment name before preparing edited CSVs or starting a new run.
si_llm_experiment="${SI_LLM_EXPERIMENT:-pinyin-lexical-v1}"
si_llm_config="${SI_LLM_CONFIG:-$si_llm_root/configs/small-pinyin.json}"
si_llm_csv="${SI_LLM_CSV_ROOT:-$si_llm_root/data/pinyin-csv}"
si_llm_data="${SI_LLM_DATA:-$si_llm_root/data/prepared/$si_llm_experiment}"
si_llm_run="${SI_LLM_RUN:-$si_llm_root/runs/small-$si_llm_experiment}"
si_llm_reports="${SI_LLM_REPORT_ROOT:-$si_llm_root/reports/small-$si_llm_experiment}"
si_llm_checkpoint="${SI_LLM_CHECKPOINT:-$si_llm_run/best.pt}"
si_llm_device="${SI_LLM_DEVICE:-mps}"
si_llm_threads="${SI_LLM_THREADS:-4}"
