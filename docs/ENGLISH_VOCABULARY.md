# English vocabulary maintenance

Edit the flat category CSVs in [Data/English](../Data/English/). Supply an
exact output `text`, a lowercase `reading`, and a nonnegative integer
`weight`. Keep the reading explicit for names and titles with punctuation,
spaces or digits. For a domain, the reading is the full lowercase hostname,
including its dots and any hyphens or digits. Case-distinct output forms
are distinct entries. Repeating an exact text/reading pair adds its counts.

The base uses the Wanxiang-derived English CSV from revision `20a5d03`.
The domain category includes Cloudflare Radar data under CC BY-NC 4.0. Bucket
membership records selection by the source and does not measure typing
frequency. Preserve the data terms and attribution when distributing
the vocabulary. [English dictionary notices](../mac/SI/Core/Resources/English/) · [Historical English attribution](../mac/SI/Resources/EnglishVocabularyNotices.txt) · [Historical frequency-data attribution](../mac/SI/Resources/RankingNotices.txt)

## Common English additions

[common.csv](../Data/English/common.csv) contains SI-authored additions,
including the article `a`. Continuous spelling such as `sendaenglish`
can produce `send a english`. Its position depends on search and
shortlisting. The movie category has its own CSV.

Use the same Rust compiler and validation commands as Chinese vocabulary.
[Build and validate the lexicon](CHINESE_VOCABULARY.md) · [Candidate ranking](UNIFIED_RANKING.md)
