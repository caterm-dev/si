# Vocabularies and decoding

SI maintains explicit `text,reading,weight` entries in
[Data/Chinese](../Data/Chinese/) and [Data/English](../Data/English/).
The Rust compiler sums counts for identical text, reading, and language
across category files. Different readings, casing, and exact output bytes
retain separate identities. Xcode builds and bundles `SIEngine/main.silex`
and accepts an optional paired word-gram snapshot.

Both languages use the Rust word lattice for exact spans and final-word
completion. Apostrophes constrain spelling boundaries. Pinyin aliases keep
their exact source consumption, and English paths preserve typed casing.
The engine retains an exact literal and allows both enabled languages to
compete by score. Constructed paths and the candidate window have separate
bounds. See [Rust conversion](ARCHITECTURE.md#rust-conversion).

Personal phrases and opted-in learning are local inputs to conversion.
The dictionary compiler reads maintained vocabulary files. History is
stored separately. See [the privacy policy](PRIVACY.md).

Run `./scripts/si-lexicon-build.sh` to compile a standalone lexicon and
`cargo test --locked -p si-engine --test conversion` to check the search.
Attribution accompanies the packaged resources. See [Chinese vocabulary
maintenance](CHINESE_VOCABULARY.md) and [English vocabulary
maintenance](ENGLISH_VOCABULARY.md).
