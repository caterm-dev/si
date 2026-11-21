# Candidate ranking

## Rust search

The Rust engine loads a count-based `.silex` lexicon and can load a paired
`.sigram` file keyed by that lexicon's word IDs. It scores exact matches,
completions and constructed paths using word frequencies and spelling costs.
Frequencies divide each word's count by the total across languages in its
lexicon. With grams present, the search interpolates continuation frequencies
with shorter histories and unigram evidence. It retains at least 20% of the
lower-order probability at each step. Word IDs stay in the same history
through Chinese and English transitions. See [Rust conversion](ARCHITECTURE.md#rust-conversion).

Chinese and English matches share one bounded search, with mixed paths
available when both languages are enabled. Direct dictionary matches are
available independently of the beam. Preview uses a smaller beam than full
conversion. Exact outputs may still be missed during composed search.
Ordinary macOS conversion can also send the full preceding field text to the
local engine. Rust uses the last sentence's ending word history to adjust the
score of the first word before pruning, independently of Personal Learning.
The separate [offline models](../llm/README.md) have their own evaluation
workflows.

## Source spans and Personal Learning

A prefix's score uses only the spelling it consumes. For example, the
lexical score of `词` for the `ci` prefix of `cichuxiande` is the same
as for standalone `ci`. Confirming it leaves `chuxiande` editable.
Apostrophes and ü/v/u: spellings keep their original source boundaries.

Rust accepts eligible length-weighted token and exact consumed-spelling
preferences before pruning. Their maximum contributes up to 32 frequency
points, and the base search retains alternatives independently. Swift
applies eligible preferences and adds five presentation points for each
matched ASCII letter, ASCII digit or ü in the consumed source. The literal
and paths containing unrecognized verbatim spans receive no coverage
reward. Learned whole-spelling corrections and explicit personal pins
receive their placement described in [Personal Learning](ARCHITECTURE.md#personal-learning).

## Merge and candidate window

Swift merges by candidate identity, including language, exact output and
consumed span. Pins have priority, followed by a remembered exact
whole-spelling choice. Ordinary complete results precede prefixes, and
longer consumed prefix spans precede shorter spans. Within the same span,
score and then identity determine the order. Nonempty input always retains
its exact spelling as the final literal candidate.

The window filters unsupported glyphs, then uses a 27-result ordinary
budget that includes the literal. Generated displayable exact Chinese
dictionary characters remain pageable beyond that budget. Only the first
four ranked positions can retain ordinary constructed multiword results or
dictionary completions, including single-entry completions. At most nine
exact word choices (including prefixes and personal phrases) remain, in
engine order. Chinese dictionary characters and punctuation do not consume
the nine-word budget.
The engine and Settings preview have access to the full result set.
See [candidate presentation](ARCHITECTURE.md#candidate-presentation).

## Verification

Use the [Rust and bridge checks](TESTING.md#automated-checks) for synthetic
coverage of ranking, spelling, mixed output, learning and source spans.
The [ranking regression set](../eval/README.md) measures recall and ranking
within its explicit exported candidate pool.
