# Run from the repository root with: make -C llm <target>
PYTHON ?=
ifneq ($(strip $(PYTHON)),)
export SI_LLM_PYTHON := $(PYTHON)
endif
CONFIG ?= llm/configs/0.4b-static-csv.json
CSV_ROOT ?= llm/data/csv
DATA ?= llm/data/prepared/static-csv-v1
RUN ?= llm/runs/0.4b-static-csv-v1
REPORT ?= llm/reports/0.4b-static-csv-v1
DEVICE ?= auto
INPUT ?= nihao
SMOKE_OUTPUT ?=
export SI_LLM_INPUT := $(INPUT)
export SI_LLM_SMOKE_OUTPUT := $(SMOKE_OUTPUT)

.PHONY: setup check smoke size prepare train resume validation evaluate test infer predict export

setup:
	./scripts/setup.sh

check:
	./scripts/check.sh

smoke:
	@if [ -n "$$SI_LLM_SMOKE_OUTPUT" ]; then ./scripts/smoke.sh --output "$$SI_LLM_SMOKE_OUTPUT"; else ./scripts/smoke.sh; fi

size:
	./scripts/size.sh --config "$(CONFIG)"

prepare:
	./scripts/prepare.sh --config "$(CONFIG)" --csv-root "$(CSV_ROOT)" --output "$(DATA)"

train:
	./scripts/train.sh --config "$(CONFIG)" --data "$(DATA)" --run "$(RUN)" --device "$(DEVICE)"

resume:
	./scripts/resume.sh --config "$(CONFIG)" --data "$(DATA)" --run "$(RUN)" --device "$(DEVICE)"

validation evaluate:
	./scripts/validation.sh --checkpoint "$(RUN)/best.pt" --data "$(DATA)" --output "$(REPORT)-validation.json" --device "$(DEVICE)"

test:
	./scripts/test.sh --checkpoint "$(RUN)/best.pt" --data "$(DATA)" --output "$(REPORT)-test.json" --device "$(DEVICE)"

infer predict:
	./scripts/infer.sh --checkpoint "$(RUN)/best.pt" --input "$$SI_LLM_INPUT" --device "$(DEVICE)"

export:
	./scripts/export.sh --checkpoint "$(RUN)/best.pt" --output "$(RUN)/inference.pt"
