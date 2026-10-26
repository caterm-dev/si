#!/bin/bash
set -euo pipefail
printf 'Data generation is retired from the normal workflow.\nEdit llm/data/csv/{train,validation,test}/*.csv and run llm/scripts/prepare.sh --output NEW_DIRECTORY.\nHistorical generator: python -m llm.build_corpus --help\n' >&2
exit 2
