# Explicit small-reranker stages. Run from any cwd with make -C /path/to/this/folder.
.DEFAULT_GOAL := help
.PHONY: help setup size data prepare run train resume validation test evaluate evaluate_suite rank export check smoke

help:
	@printf '%s\n' 'Small character-LM reranker baseline' \
	  'Stages: setup size data run resume validation test evaluate evaluate_suite rank export check smoke' \
	  'Use scripts directly for arguments; SI_RERANKER_SMALL_* selects paths and device.'

setup size data prepare run train resume validation test evaluate evaluate_suite rank export check smoke:
	./scripts/$@.sh
