# Model-family entry point. Existing targets retain their conversion meaning.
.DEFAULT_GOAL := help
.PHONY: help setup check smoke size data prepare run train resume validation evaluate test infer predict export

help:
	@printf '%s\n' 'Model directories:' \
	  '  pinyin_to_text  Existing spelling-to-text training framework' \
	  '  reranker_small Offline 7.4M LM training, scoring, evaluation and export' \
	  '  reranker_large Reserved for pause-time candidate reranking; not implemented' \
	  'Use: make -C llm/pinyin_to_text <target> or make -C llm/reranker_small <target>'

setup check smoke size data prepare run train resume validation evaluate test infer predict export:
	$(MAKE) -C pinyin_to_text $@
