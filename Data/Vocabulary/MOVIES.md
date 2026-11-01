# Movie titles, 2007–2026

The [review catalog](movie-catalog.csv) contains 400 selected films across the twenty calendar years 2007–2026, as of October 28, 2026. It covers major Chinese and international theatrical releases, popular animation and selected award films. This is a curated selection, not every film released worldwide, a box-office ranking or a claim of production coverage. Existing older titles and cinema vocabulary remain available.

Chinese titles belong in [chinese/movie.csv](chinese/movie.csv); English titles belong in [english/movie.csv](english/movie.csv). The catalog records the paired names and release year for maintenance only. It is not loaded at runtime and does not override subsequent CSV edits. Years generally follow the first commercial release; festival premieres and regional release dates can differ. Remakes can share a name: the 2010 and 2025 versions of *How to Train Your Dragon* use one English dictionary identity.

## Entries and weights

- Chinese movie category: 810 rows, retaining all 429 previous rows and adding 381 category rows. Of these additions, 212 are new public text/reading identities; the rest reuse existing public vocabulary, including alternate readings. Total Chinese dictionary: 953,837 effective identities.
- English movie category: 399 rows for the catalog's 400 films. The initial addition contained 350 new text/reading identities and reused 49 existing identities. Their current local category weights are all 10. The movie update brought the English dictionary to 63,952 effective identities; later categories, including [domains](DOMAINS.md), add to that total.
- All local movie category rows now use weight 10, also the default for new SI additions. This is an editorial prior, not measured popularity. Upstream base/imported category identities retain their own weights and take precedence over local copies; local duplicates merge by maximum weight.

Case-only collisions with ordinary English words retain the established form, for example `inception`, `frozen` and `up`. Initial-capital or uppercase input uses the existing case behavior. Space/punctuation variants such as `Soul Mate` and `soulmate`, or `Home Coming` and `homecoming`, remain separate exact outputs with the same typing key; neither removes the ordinary word.

## Typing

Chinese uses explicit Pinyin readings. Numbers in output have spoken Chinese readings, for example `feichirenshengsan` → `飞驰人生3`; separators and punctuation in the film title are output data. Reviewed readings include `chang'an`, `ne'zha`, `chong'sheng`, `zhao'ge`, `xiang'mo`, and `nv`/`lv`. Existing title variants without punctuation remain available.

English titles use a continuous alphabetic key. Remove spaces and punctuation; spell each Arabic digit individually in English. Examples:

| Input | Exact title output |
| --- | --- |
| `avengersendgame` | `Avengers: Endgame` |
| `dontlookup` | `Don't Look Up` |
| `walle` | `WALL-E` |
| `insideouttwo` | `Inside Out 2` |
| `pegasusthree` | `Pegasus 3` |
| `bladerunnertwozerofournine` | `Blade Runner 2049` |

Roman numerals remain letters (`Frozen II` uses `frozenii`). English keys contain 1–64 lowercase ASCII letters. Outputs retain printable ASCII spaces, punctuation and numbers; they cannot contain controls or leading/trailing spaces. Diacritics are not supported by this English CSV contract (`Les Miserables` uses an ASCII spelling). Completion scores use typing-key length rather than displayed title length. Film titles use the same dictionary/trie and bounded mixed search as other vocabulary; the category adds no ranking bonus. A short prefix does not guarantee a particular long title survives bounded prediction. The exact original input remains available, and disabled languages do not supply movie candidates.

Multiword titles are atomic dictionary entries and do not establish title-specific sentence-context quality. No new language switch, runtime download, personal data retention or host permission is introduced.

## Provenance and factual review

The additions and readings are SI-maintained editorial vocabulary under the repository's GPLv3 license. No third-party dictionary, plot text, ratings, posters, full movie database or system dictionary was imported. Reused rows retain the upstream provenance and notices in [meta.json](meta.json). The catalog is a factual list of titles, not a licensed corpus import. The `movie-titles-2007-2026` curation record in `meta.json` records its date, scope and checksum; update that record when intentionally revising the catalog.

Reference pages used for release/title spot checks, especially the current year:

- [Academy Awards ceremony archive](https://www.oscars.org/oscars/ceremonies), including [2025](https://www.oscars.org/oscars/ceremonies/2025).
- [China Film Administration, 2026 domestic release certificates](https://www.chinafilm.gov.cn/xxgk/gsxx/dygyxkz/202604/t20260403_983753.html). Certificates alone do not establish a release date.
- [China Film News, February 25, 2026 Spring Festival audience report](https://chinafilmnews.cn/Html/2026-02-25/20256.html).
- [China Film News, May 20, 2026 international release/box-office report](https://www.chinafilmnews.cn/UploadFiles/file/20260520/202605200205344107.pdf).
- [Disney: Hoppers](https://movies.disney.com/hoppers) and [Toy Story 5](https://movies.disney.com/toy-story-5).
- [Well Go USA: Panda Plan: The Magical Tribe](https://wellgousa.com/films/panda-plan-2-magical-tribe).
- [1905: Per Aspera ad Astra](https://www.1905.com/mdb/film/2258069/) and [How to Train Your Dragon (2025)](https://www.1905.com/mdb/film/2258136/).

The category CSVs remain the editable dictionary source; compile/check them with the [normal offline workflow](README.md#compile-and-verify). Further aliases, regional translations, less prominent films and independent title/reading review remain maintenance work.
