# Chinese vocabulary maintenance

Edit the flat category CSVs in [Data/Chinese](../Data/Chinese/). Each row
has `text,reading,weight`. Use lowercase Pinyin with apostrophes between
syllables and `v` for ü in the dictionary key. Keep the exact output bytes
and supply an explicit nonnegative integer count. Polyphonic readings
remain separate entries. Repeating an exact text/reading pair across
categories adds its counts.

To validate both languages with the standalone Rust compiler, build to a new
path. Debug and Release package the local lexicon and tracked word grams
under `Data/Engine/`.

```sh
si_vocab_check="$(mktemp -d)"
./scripts/si-lexicon-build.sh "$si_vocab_check/main.silex"
cargo run --locked -p si-cli -- check-resources "$si_vocab_check/main.silex"
```

Build a fresh lexicon when removing rows, since incremental imports retain
entries absent from the input CSVs. Regenerate word grams for the new
lexicon before packaging the pair.

Keep source terms and notices with any vocabulary contribution. Wanxiang
imports remove tones and merge tone-collapsed source identities before
publication. [Wanxiang attribution](../mac/SI/Core/Resources/English/Wanxiang-NOTICE.txt) · [Chinese corpus notices](../mac/SI/Core/Resources/Chinese/) · [Rust resource workflow](ARCHITECTURE.md#rust-resource-workflow)
