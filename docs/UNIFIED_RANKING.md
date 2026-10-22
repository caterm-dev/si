# Candidate ranking

The default Chinese decoder uses SI's native Swift MSIME adaptation. The former bilingual wordfreq/character-boundary objective no longer defines default Chinese ranking. English spellings and functionality are retained through a maintained SQLite dictionary with the same schema, immutable reader and weight unit as Chinese. Private personal phrases and aggregate preference records remain separate from public dictionary data.

## Shared dictionary weight unit

`Data/DictionaryFormat.json` pins `si-relative-frequency-v1`: one point is one share of a fixed reference mass of 7,694,577,936, the initial Chinese text/reading weight sum. Chinese stored weights stay unchanged. Initial English probabilities, normalized over retained words and an unknown floor, were multiplied by that mass and rounded to integer weights. Snapshot provenance records the conversion and rounding. Both public overlays use these same units. Daily additions/deletions do not rescale stored weights. The shared schema stores `key`, `jp`, `value`, `weight` and versioned metadata; no English source-priority score or centibel encoding reaches the runtime.

This aligns dictionary-relative priors, not underlying corpora or complete sentence-score calibration. English computes word probabilities from its integer weights plus the pinned unknown weight and retains its word-prefix/segmentation costs; small rounding differences from its previous centibel-derived probabilities are expected. Chinese keeps its insertion costs and word-context increments. CandidateEngine preserves the Chinese provider's internal order while explicitly placing exact English, complete Chinese/English sentences and mixed choices; it does not globally sort the decoders' full scores.

## Bounded mixed lexical search

With English and Chinese enabled, the shared lexical decoder builds Chinese word edges from complete Pinyin readings and English word/completion edges from the trie. Its continuation cost in bits is:

```text
wordCost = (20 - ln(max(1, weight)) + (single Chinese character ? 2 : 0)) / ln(2)
```

This subtracts the Chinese-only lattice's fixed 20-nat offset per consumed syllable, allowing differing English and Chinese spans to compete without rewarding extra Chinese syllables. Both word types use the same relative weight points and insertion prior. English adds its finite word-prefix channel; a generated language-transition cost is applied separately. Positive Chinese bigram increments reduce continuation cost within Chinese runs, weighted by two; English/personal boundaries reset that context. Chinese-only decoding retains its existing score and trigram stage. Mixed search does not add a new corpus or claim calibrated probabilities.

The existing bounded base/personalized beams and consumed-spelling prefix selection remain, with no learned preference for a path containing personal/verbatim nodes. Mixed leaders never authorize automatic confirmation. Full Chinese readings keep their Chinese leader; exact English words and fully lexical English sentences are protected from accidental mixed completions. Otherwise a mixed whole path such as `woxiangyaodeploy` → `我想要deploy` can lead. Alternative language identities and exact original spelling remain available. Bounded search can omit desired paths; mixed initial-only Chinese edges and incomplete Chinese-tail prediction remain outside this integration.

## Dictionary and sentence scores

The [MSIME maintenance pipeline](CHINESE_VOCABULARY.md) preserves integer source weights and explicit readings in a generated SQLite dictionary. For a word of `n` syllables, the current base score in natural-log units is:

```text
score = ln(max(1, weight)) + 20 × (n - 1) - (n == 1 ? 2 : 0)
```

Characters and words use the same log-frequency coefficient. SI deliberately replaces upstream's single-character `ln(1,000,000)` deduction (about 13.82 nats) with a small two-nat insertion cost. A tenfold frequency advantage contributes `ln(10)` (about 2.30 nats), enough to overcome that extra cost when coverage and token count otherwise agree. The residual cost discourages excessive character splitting. Multiplying weights without changing the structural scale would not solve the imbalance.

For a path consuming `N` syllables and `K` tokens, the length term sums to `20 × (N - K)`: at fixed coverage this is an ordinary per-token insertion prior, not an unlimited bonus for splitting into more fragments. The 20-nat insertion prior is retained after development comparisons; reducing it substantially regressed everyday sentences. Candidate weights, readings and context resources are unchanged. No word-specific exclusions or bonuses were added.

The zero floor is computational; stored weights retain their original values. Positive word-bigram increments contribute during continuation search with multiplier two. Up to six distinct terminal sentences survive before word-trigram rescoring; a sole surviving sentence does not receive that comparison increment. These remain heuristic model scores, not normalized sentence probabilities or estimates of linguistic correctness. Bounded search can discard a desired sentence.

The lattice retains a 32-path base beam, a separately bounded personalized lane, at most seven syllables and 32 lexical rows per span. Direct lexical and personal matches remain independently available. Natural-log arithmetic continues through search and rescoring; presentation/preference boundaries convert into bits. Equal-score heap and terminal sorting follow the pinned upstream behavior. See [the source study](MSIME_ALGORITHM.md) for the upstream algorithm and resource revisions; the smaller character cost is an intentional SI divergence.

## Presentation and personalization

Exact lexical placement, constructed sentences and incomplete/initial choices follow explicit candidate policy. The engine preserves Chinese provider order; sharing dictionary weight units does not make the decoders' full scoring objectives interchangeable. Language-aware identity and exact literal fallback remain intact. The input window shortlists at most 27 results; engine and preview retain full results.

Whole-input and eligible previous-word preferences apply before presentation limits. Token and whole-input frequency share a 32-point cap through their maximum; previous-word preferences add at most 12 points. Prefix preferences use only consumed source spelling. Personal or verbatim paths never train learning/context, and no sentence is automatically split into retained token records. English preferences continue to rank matching English lexical entries.

Explicit personal nodes use the retained 10,000 insertion prior, with a one-bit preferred-phrase adjustment; these are user override priors, not corpus frequency. The 12-alternative personal-node fanout and 4,096-byte constructed-output bound remain. Retention, expiry, consent and deletion rules are unchanged.

Automatic confirmation retains its English/code lexical safeguard and existing opt-in rules. Manual selection and exact original-input commits remain available.

## Retained fixtures and validation

`Data/Ranking/calibration.json` and the evaluation/holdout/phonetic JSON files contain authored synthetic examples, not imported vocabulary or personal history. `scripts/english_dictionary.py build` reproduces the maintained English database from its adopted weighted snapshot and SI overlay. `scripts/ranking.py` reproduces retained attribution and the synthetic transition constant; its wordfreq importer is used only by explicit English `snapshot` adoption. Wordfreq 3.1.1 supplies English frequency estimates under its retained CC-BY-SA-4.0 attribution; code notices and corpus credits remain in `Data/Ranking/wordfreq-3.1.1/` and bundled `RankingNotices.txt`. English vocabulary pins, licenses and selection remain documented in [English maintenance](ENGLISH_VOCABULARY.md). Historical mixed and former-model tests remain visible as unmet capability checks.

```sh
python3 scripts/msime_dictionary.py build --check
python3 scripts/english_dictionary.py build --check
./scripts/vocabulary.sh build --check
python3 scripts/ranking.py --check
python3 -m unittest discover -s Tests/VocabularyTests -v
./scripts/test.sh
./scripts/build.sh
```

Compilation and dictionary reproducibility do not establish Chinese quality or host compatibility. See [the current verification record](VERIFICATION.md) and [unfinished work](IMPLEMENTATION_PLAN.md).
