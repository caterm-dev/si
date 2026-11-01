# Basic domain vocabulary

[english/domain.csv](english/domain.csv) contains 1,209 full ASCII domain/host names: the original 304 SI-authored entries merged with Cloudflare Radar's 1,000-domain bucket (95 overlaps, 905 additions). Standalone suffix entries such as `.ai`, `.com` and `.co.uk` are excluded. The merged English dictionary contains 65,161 effective text/reading identities. This is a familiar-name selection, not every registered domain, a DNS resolver or a service-availability directory.

The names cover search/reference, developer tools and documentation, cloud services, design/productivity, research, email, media, shopping, education and public organizations. Useful subdomains are explicit entries; no `www.` or other subdomains are generated automatically. `example.com`, `example.org` and `example.net` are reserved documentation examples.

## Editing and typing

Rows use `text,reading,weight`. Both `text` and `reading` are the same lowercase domain, including every dot, hyphen and digit. A domain has at least two nonempty labels, a final alphabetic label of 2–63 characters, at most 63 ASCII letters/digits/hyphens per label, no leading/trailing label hyphens, and at most 253 characters overall. Schemes, ports, paths, trailing dots and standalone suffixes are excluded from this category.

```csv
text,reading,weight
google.com,google.com,100
rust-lang.org,rust-lang.org,100
mail.163.com,mail.163.com,100
```

Input `google.com` looks up `google.com`; `googlecom` is not an alias. A prefix such as `google.` can offer `google.com` as a completion. The ordinary word/title categories keep their existing alphabetic readings. Domain keys retain punctuation and numeric bytes in the shared English trie; completion costs use that literal key length. New domain entries use editorial weight 10 without rescaling existing vocabulary.

Normal English casing, candidate confirmation, spacing and literal-input policies still apply. The existing punctuation policy controls whether a dot remains in composition or confirms it; number keys keep their existing candidate-selection behavior. Adding domain vocabulary does not implement a browser address mode, override those policies or guarantee that every domain can be entered as one composition in every host. The exact original input remains available. Native host behavior still requires manual checks.

The compiler discovers the file automatically and packages it into the shared English SQLite dictionary. App, Settings preview and package tests use the same vocabulary. This category adds no runtime networking or special ranking bonus. Shortlists remain bounded, so a particular domain is not guaranteed to appear from a short prefix. No browsing history, personal hostnames, private network domains, document contents or clipboard data were used.

## Fetch and merge Cloudflare Radar

The optional maintenance script downloads the latest `ranking_top_1000` CSV from
Cloudflare Radar and merges its unordered set of 1,000 domains. Cloudflare's
weekly bucket has no individual numerical ranks. It is based on DNS resolver
queries, not measured input-method frequency.

1. Copy [.env.example](../../.env.example) to `.env` in the repository root and set
   `CLOUDFLARE_RADAR_API_TOKEN` to a token with **Radar Read** permission. `.env` is
   ignored by Git. A process environment variable with that name also works;
   `CLOUDFLARE_API_TOKEN` is accepted as a fallback. Do not put credentials in a
   command argument or a committed file. Dotenv values are parsed as data without
   executing shell expressions.
2. Run the updater and then compile/verify the ordinary dictionaries:

```sh
python3 scripts/cloudflare_radar_domains.py
python3 scripts/csv_dictionary.py build
python3 scripts/csv_dictionary.py build --check
python3 -m unittest discover -s Tests/VocabularyTests -v
./scripts/test.sh
./scripts/build.sh
```

Use `--env-file /path/to/ignored.env` for another local credentials file. To replay
an already downloaded snapshot without a token or network:

```sh
python3 scripts/cloudflare_radar_domains.py --input Data/Vocabulary/CloudflareRadar/top-1000.csv
```

The script requires exactly 1,000 unique, supported full lowercase ASCII domains.
Malformed/truncated responses, authentication failures and incompatible data
abort without adopting a partial list. Existing names and their exact weights
remain; new names receive weight 10 with identical text/reading. A blank local CSV weight also uses 10. Repeating an
import does not duplicate records. No suffix-only entries are added. An error
during publication rolls back the source writes, and source edits made during
the download cause an abort instead of overwriting those edits.

The first successful merge saves the original SI selection as
`Data/Vocabulary/CloudflareRadar/si-authored.csv` and retains the raw current Radar
snapshot as `top-1000.csv` beside it. `meta.json` retains each source's checksum,
the API alias/endpoint, retrieval time, public response headers, transformations,
license and merged collection checksum/count. Later snapshots replace the current
snapshot; ordinary offline builds never fetch data or restore previously deleted
rows. Re-running this explicit importer may re-add a domain still in the source.

Radar data retains **CC BY-NC 4.0**, including its NonCommercial restriction. It
is not relicensed under SI's GPLv3 code license. The [bundled attribution](../../mac/SI/Core/Resources/English/CloudflareRadar-NOTICE.txt)
and [full license](../../mac/SI/Core/Resources/English/CloudflareRadar-CC-BY-NC-4.0.txt)
apply to Radar-derived records and must accompany redistribution; no commercial
redistribution permission is asserted. Review those data terms before distributing
a combined dictionary. This command is for explicit local maintenance, with no
runtime downloads, automatic refresh or credential storage in app resources.

## Provenance and limits

The original SI-authored seed is under the repository's GPLv3 license and is retained separately as [si-authored.csv](CloudflareRadar/si-authored.csv). The current [Radar snapshot](CloudflareRadar/top-1000.csv) was retrieved through the authenticated API on October 28, 2026 and retains CC BY-NC 4.0. The seed was authored without importing a third-party dictionary or public suffix dataset. Radar's separate source record and CC BY-NC 4.0 attribution apply to the imported data. Names identify their respective services; inclusion is not an endorsement or a guarantee of ownership, availability or future spelling. Familiar alternate domains may redirect. Non-ASCII/IDN coverage remains outside this selection.

Reference checks: [IANA's example-domain documentation](https://www.iana.org/help/example-domains), [Python's site](https://www.python.org/) for documentation/PyPI names, and [Mozilla's site](https://www.mozilla.org/) for public service names. The `basic-domains` curation record in [meta.json](meta.json) retains the category checksum and scope; update it when changing the file.

Use the [standard offline build/check workflow](README.md#compile-and-verify) after edits. Automated tests validate source syntax, full-name coverage, literal readings, lookup output, language filtering and exact literal preservation. They do not contact the listed sites or establish live host compatibility.
