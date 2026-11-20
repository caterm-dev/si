# Run from the repository root with: make -C llm/pinyin_to_text <target>
PYTHON ?=
ifneq ($(strip $(PYTHON)),)
export SI_LLM_PYTHON := $(PYTHON)
endif
CONFIG ?= llm/pinyin_to_text/configs/contextual-pinyin.json
CSV_ROOT ?= llm/pinyin_to_text/data/syllable-csv
DATA ?= llm/pinyin_to_text/data/prepared/pinyin-syllable-100k-v1
RUN ?= llm/pinyin_to_text/runs/small-pinyin-syllable-100k-v1
REPORT ?= llm/pinyin_to_text/reports/small-pinyin-syllable-100k-v1
DEVICE ?= mps
INPUT ?= nihao
SYLLABLES ?= $(if $(filter nihao,$(INPUT)),ni hao)
SMOKE_OUTPUT ?=
export SI_LLM_INPUT := $(INPUT)
export SI_LLM_SYLLABLES := $(SYLLABLES)
export SI_LLM_SMOKE_OUTPUT := $(SMOKE_OUTPUT)

.PHONY: setup check smoke size data prepare run train resume validation evaluate test infer predict export

setup:
	./scripts/setup.sh

check:
	./scripts/check.sh

smoke:
	@if [ -n "$$SI_LLM_SMOKE_OUTPUT" ]; then ./scripts/smoke.sh --output "$$SI_LLM_SMOKE_OUTPUT"; else ./scripts/smoke.sh; fi

size:
	./scripts/size.sh --config "$(CONFIG)"

data prepare:
	./scripts/prepare.sh --config "$(CONFIG)" --csv-root "$(CSV_ROOT)" --output "$(DATA)"

run train:
	./scripts/train.sh --config "$(CONFIG)" --data "$(DATA)" --run "$(RUN)" --device "$(DEVICE)"

resume:
	./scripts/resume.sh --config "$(CONFIG)" --data "$(DATA)" --run "$(RUN)" --device "$(DEVICE)"

validation evaluate:
	./scripts/validation.sh --checkpoint "$(RUN)/best.pt" --data "$(DATA)" --output "$(REPORT)/validation.json" --device "$(DEVICE)"

test:
	./scripts/test.sh --checkpoint "$(RUN)/best.pt" --data "$(DATA)" --output "$(REPORT)/test.json" --device "$(DEVICE)"

infer predict:
	./scripts/infer.sh --checkpoint "$(RUN)/best.pt" --input "$$SI_LLM_INPUT" --device "$(DEVICE)" $(if $(strip $(SYLLABLES)),--syllables "$$SI_LLM_SYLLABLES")

export:
	./scripts/export.sh --checkpoint "$(RUN)/best.pt" --output "$(RUN)/inference.pt"
