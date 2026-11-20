# Pinyin-to-text training data

The default [100,000-example collection](syllable-csv/README.md) contains
explicit syllable sequences and optional preceding text, with 96,000 training,
2,000 validation and 2,000 test rows. It is derived from SI's maintained
Chinese dictionary. See the collection guide for provenance and reconstruction.

The [small contextual fixture](contextual-pinyin-csv/train/examples.csv) has
six training, three validation and three test rows for smoke checks.

The [Chinese corpus workspace](../../../corpus/README.md) prepares public text
and lexical reading tables separately. The default collection uses the pinned
dictionary directly. Private learning archives, personal phrases and input
history exports stay outside these collections.

Run `./llm/pinyin_to_text/scripts/data.sh` to prepare the default training
bundle. Prepared files, source snapshots, checkpoints and reports are ignored
by Git. See the [training guide](../README.md) for new runs and resume.
