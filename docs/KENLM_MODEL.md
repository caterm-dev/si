# Current delivery model — coarse vocabulary, November 10, 2026

The current refit resegments all seven raw-text-v2 sources with the coarse
`Data/Chinese/*.csv` vocabulary. Chinese/English source CSVs are frozen in the
run. Unigram Viterbi uses the Chinese count total of 1,804,102,196 and a
0.5-count unknown floor, matching the app's rebuilt SQLite dictionary.
Chinese dictionary snapshot SHA-256:
`be1168ed2f136dfe0a35d0e47925e303edb3e9666787cfbec5f4a5b76304b419`.
No intermediate historical frequency table or HanLP corpus inference is used.

- Sources: LCCC, mC4, Kubernetes, TensorFlow, MDN, SI and Dialogue; Wikipedia excluded.
- Raw tokenized population: 48,324,791 sentences / 365,230,074 tokens.
- Exact-line deduplication: 17,762,036 unique lines; 30,562,755 duplicates removed.
- Final clean2 fit: 17,739,045 sentences / 163,435,423 tokens.
- Order 4; pruning `0 0 1 2`; trie `-a 22 -q 8 -b 8`.
- Binary: 167,546,159 bytes (159.78 MiB).
- SHA-256: `e80394a8b5604e9c715fba23239705199549159c7beacf1e738bb8c1e2e2823d`.
- Retained model/full metadata: `corpus/kenlm/models/current/`.
- Working run and signed app: `.build/kenlm-coarse-dictionary-20261110/` and
  its `app-stage/SI.app`.
- Signed delivery ZIP: `.build/SI-coarse-vocabulary-20261110.zip`,
  201,562,477 bytes; SHA-256
  `62bbb858e70c369f7ad62e12536abe9d44c911cccc9f0fbb390fc7b323204572`.

Train-only heldout PPL including true OOV is 163.508504 with 1,953 true OOV
tokens. Tokenization changed, so this is not directly comparable to the fine
model's PPL. Exact-line separation and all 17,763 frozen block routes pass
independent checks; document/dialogue and near-duplicate independence remain
unestablished. The final model includes heldout and has no independent heldout
score. Ranking settings were reused without tuning.

All 20 unchanged natural/reversed sanity pairs pass (median log10 margin per
token 1.117867); default and lazy scores match. Fifteen native SI model,
context and Settings tests pass with the actual model. Marker probabilities
match the pinned KenLM CLI reference. Release build, Developer ID deep/strict
signature verification and the same checks after ZIP extraction pass.
Embedded model and Chinese/English SQLite hashes match their source artifacts;
source/model notices accompany the model. Local installation remains deferred
at the user's request. No live-host typing or compatibility checks were made.

Reproduce with `corpus/.venv/bin/python scripts/retrain_kenlm.py --run .build/<fresh-run>`.
Use `--stage tokenize` / `--stage train` for separate stages. The working run
retains code/tool/dictionary/source pins, origin ranges, mappings, split audits,
train-only/final models, commands, native references and artifact/delivery audits.
Generated text, models and reports are ignored. Retained delivery assets stay
outside `.build` as described below.

For native verification, set `SI_TEST_KENLM_BUNDLE` to the staged app's
`Contents/Resources/KenLM`, `SI_TEST_KENLM_INSTALLATION` to the run's
`test-installation`, and `SI_TEST_KENLM_REFERENCE` to
`corpus/kenlm/models/current/native-reference.json`, then run
`./scripts/test.sh --disable-sandbox --filter 'KenLMModelTests|KenLMContextTests|LanguageSettingsTests'`.

# Previous delivery model — fine vocabulary, November 10, 2026

The earlier count-dictionary fit used the fine vocabulary snapshot
`e2e629e1ef1a2e4bb8b708f9860a73c4c549f5910fb3fe1f4c92480de226be5e`.
Its binary remains under
`corpus/kenlm/models/6d5652152689cad06ef35c689783f3f1f357a9987a2e612745cd09406ab97f09/`:
161,309,373 bytes (153.84 MiB). The final fit contained 17,737,492 sentences /
170,371,865 tokens. Train-only heldout PPL was 133.788260 with 1,629 OOVs;
all 20 sanity pairs and the native integration checks passed.
The original working run and ZIP were removed by build-cache cleanup; the
model was recovered byte-identically and retained separately. This historical
model is no longer selected by `current`.

# Previous delivery model — November 9, 2026

The selected model is the full-data Chinese KenLM refit from raw-text-v2,
using LCCC, mC4, Kubernetes, TensorFlow, MDN, SI and Dialogue. Wikipedia is
excluded. SI's local synthetic dialogues are AI-authored, not actual chat
transcripts. Source licenses remain separate; local installation does not
establish permission to publish or redistribute a new corpus population.

The final fit already completed on November 9, 2026. It concatenated the frozen
train then heldout population, recalculated full-population clean2 frequencies
and mapping, and fitted 17,742,182 retained sentences / 145,386,390 tokens.
There was no new splitting or deduplication during final fitting.

- Order: 4; pruning: `0 0 1 2`; quantized trie: `-a 22 -q 8 -b 8`.
- Binary: 216,089,204 bytes (206.08 MiB).
- SHA-256: `0ffe49c37dded5c894bd25b69e3ec8269c13fad4b2412adc5d0f9fd88f25470a`.
- Default binary and full metadata directory:
  `.build/kenlm-raw-text-v2-no-wikipedia-p0012/final/`.
- Frozen inputs, full cleaning map, source pins, exact commands, tool hashes,
  sanity results and model metadata remain in the ignored run directories.
  The preceding `.build/kenlm-final` and `0123` runs are preserved.

The matching train-only model has heldout PPL 309.256876 including true OOV,
versus 331.257923 for the same-data `0123` model. Both use exactly the same
cleaned heldout and vocabulary. Exact-line separation does not establish
document/dialogue or near-duplicate independence. Both final models include
heldout, so their candidate comparison is descriptive, not an independent
generalization estimate. The fixed-weight comparison over 30,233 inputs raised
new-corpus whole Top-1 from 52.79% to 54.50% and Top-5 from 71.48% to 72.95%.
English whole Top-1 remained 98.20%. Ranking weights are unchanged.

`scripts/install.sh` and release packaging copy and hash-check this final model,
metadata and notices into the staged app before signing. New source selection
and the pinned Dialogue attribution accompany the existing corpus notices.
Runtime loading accepts both `0012` and the previous `0123` configuration;
other cleaning, format, size and compatibility checks remain enforced.
Plain `scripts/build.sh` builds do not embed a model and retain the versioned
App Support fallback. Bundled resources take precedence over that fallback.

Run shared tests with `SI_TEST_KENLM_BUNDLE` pointing to the staged
`Contents/Resources/KenLM` directory. This checks native loading and rejection
of unsupported pruning metadata. See [integration checks](TESTING.md#production-kenlm-ranking)
and [release packaging](RELEASING.md). Live host compatibility and the installed
process actually using the replacement remain separate manual checks.

## Local delivery verification (November 9, 2026)

The full Swift suite passed 323 tests with the staged model enabled. All 65
script tests passed; the updated release-model cases passed in a subsequent
28-test focused run. Debug and Release builds succeeded. The supported local
reinstall flow installed the Developer ID-signed app at
`~/Library/Input Methods/SI.app` and verified one selectable SI input source
without enabling or selecting it. The installed model's SHA-256, byte count,
`0012` metadata, seven-source selection and Dialogue notices were checked;
the installed app passed strict deep signature verification. Three native
model tests passed against its actual bundled resources, including loading
`0012` and rejecting unsupported pruning metadata. Live host typing remains
unverified.
## Retained delivery artifacts and build cleanup

Validated training now publishes `final.bin`, full `final.meta.json`, the native
reference and small provenance records under the ignored
`corpus/kenlm/models/<binary-sha256>/`. The `current` symlink selects the model
used by install/release. Previous versions remain until explicitly deleted.
These are delivery assets, not Swift build caches; keep them when clearing
`.build`. No model binaries are committed to Git.

`reinstall.sh` verifies the selected model before stopping SI; `install.sh`
verifies it before building/signing. Both still build Swift normally and embed
the existing trained model. An app build does not run language-model training.
Use `python3 scripts/install_kenlm_model.py --verify-only` to check readiness.
If working, retained and backup copies have all been deleted, explicitly rerun
`scripts/retrain_kenlm.py`; validated completion publishes the result automatically.
