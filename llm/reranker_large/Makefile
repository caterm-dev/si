.DEFAULT_GOAL := help
.PHONY: help setup size prepare-data prepare-extra-data prepare-distillation continue-pretrain data pools teacher pretrain distill resume validation test evaluate rank export benchmark check smoke

help:
	@printf '%s\n' '15.6M student; explicit offline stages, no automatic training' \
	  'Stages: setup size prepare-data prepare-extra-data prepare-distillation continue-pretrain data pools teacher pretrain distill resume validation test evaluate rank export benchmark check smoke' \
	  'Use scripts/<stage>.sh --help for arguments and SI_RERANKER_LARGE_* for experiment paths.'

setup size prepare-data prepare-extra-data prepare-distillation continue-pretrain data pools teacher pretrain distill resume validation test evaluate rank export benchmark check smoke:
	./scripts/$@.sh
