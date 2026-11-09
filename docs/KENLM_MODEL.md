# Current delivery model

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
