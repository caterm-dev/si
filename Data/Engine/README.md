# App conversion resources

SI packages these paired base snapshots in both Debug and Release builds.
The build copies them to
`SI.app/Contents/Resources/SIEngine/`.

| File | Contents |
| --- | --- |
| `main.silex` | Locally generated base lexicon, ignored by Git |
| `words.sigram` | Git LFS-tracked word-gram counts keyed by the paired lexicon's word IDs |

Install Git LFS and retrieve the snapshot before building or validating:

```sh
git lfs install
git lfs pull
```

The repository's `.gitattributes` rule stores this file as an LFS pointer in
Git; the working copy must contain the downloaded binary snapshot.

These snapshots were moved byte-for-byte from the existing local
`.build/si-data/` resources. Source notices and license texts accompany the
app under [Chinese notices](../../mac/SI/Core/Resources/Chinese/) and
[English notices](../../mac/SI/Core/Resources/English/). The
[resource workflow](../../README.md#rust-engine-workspace) documents dictionary
compilation, corpus ingestion and word discovery.

Generate a missing base lexicon from the maintained CSVs with
`./scripts/si-lexicon-build.sh`. Validate the pair after generating or updating
either snapshot. A fresh lexicon must use the word IDs expected by the gram
snapshot. Regenerate its word grams when the pair fails compatibility checks.

```sh
cargo run --release --locked -p si-cli -- check-resources Data/Engine/main.silex Data/Engine/words.sigram
```

The maintenance scripts use this directory for base resources. Generate a
fresh lexicon at a temporary path when removing entries, regenerate its word
grams, then replace and validate the pair together. Incremental imports preserve
existing word IDs. Generated exports, review CSVs and lock files remain ignored.
Local user dictionaries and profiles belong in ignored paths such as
`.build/si-data/`.
