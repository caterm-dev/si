# Input History export and contributed training observations

Input History has an explicit **Export Input History…** action in Settings and its history viewer. It saves one portable UTF-8 `.jsonl` file at the user's chosen destination. It exports **all saved history**, including rows hidden by search or on other pages, in submission-sequence order. Accepted queued writes finish first; unsaved failures block export instead of silently omitting entries. Repeated submissions, sequence gaps, exact source/output bytes, language, reason and timestamps survive export/restore. Records written after the snapshot begins are outside that snapshot.

Clicking **Export Input History…** opens the save panel directly. There is one export format, without backup/training choices or training-permission fields. The file can be restored or prepared as training observations with the same receiver tools.

Saving does not send/upload a file, start training or change recording consent. The owner manually decides whether/how to share it. SI does not silently export real data during build/tests. Exported files are unencrypted, use owner-only file permissions and remain separate from the local history database; deleting local history cannot delete copies already shared or backed up. Checksums detect accidental corruption, not authenticity or ownership. The file format does not declare data rights or a redistribution license.

## Receiver workflow

Use private local paths. The default export filename and `llm/private-history/` are ignored by Git. Keep received files, restored databases, CSV candidates and derived training data out of commits and public dataset uploads.

```sh
mkdir -p llm/private-history/received
# Manually put the voluntarily shared file in received/.
python3 scripts/input_history.py inspect \
  llm/private-history/received/SI-Input-History.jsonl
python3 scripts/input_history.py restore \
  llm/private-history/received/SI-Input-History.jsonl \
  --output llm/private-history/restored.sqlite3
python3 scripts/input_history.py prepare \
  llm/private-history/received/SI-Input-History.jsonl \
  --output llm/private-history/candidates
```

These standard-library commands accept the same ordinary export, run locally, print only counts/metadata and never start training. They validate the manifest/version, row types/identities, strictly increasing sequences, summary count and SHA-256 before publishing output. Invalid, truncated, duplicate-event or modified archives leave no restored output. Existing destinations are refused, not overwritten. Validation streams records into a temporary owner-only SQLite database rather than loading the history or UUID set into RAM. `restore` recreates native schema 1 exactly, including event UUIDs, timestamps, repeated rows, sequence gaps, Unicode forms and embedded NUL bytes. It does not import data into the running input method; the receiver can inspect/use the separate database offline.

`prepare` writes:

- `candidates.csv`: `input,target,language` observations (`zh`, `en`, `mixed`), retaining spelling/output as observed and preserving repeats.
- `provenance.json`: source-archive hash, preparation version, retained/excluded counts, CSV hash, unreviewed status and unassigned splits; no invented license or raw-text samples.

Default candidates include explicit and default candidate confirmations. Automatic confirmations, AI completions, passthrough/delimiter commits, literal commits and unknown-language rows are excluded. Inputs/targets must meet the current CSV reader's nonempty, 4,096-byte and no-control-character constraints. `--include-literal` additionally admits observed ASCII literal/copy tasks as English. This is an explicit preparation choice, not evidence that a literal Pinyin string was correctly converted. The full restored database still contains every valid exported record, including excluded training observations.

## Training scope and quality

The candidate CSV header matches the existing conversion CSV reader, but this command does **not** append to maintained sources, assign train/validation/test splits, declare redistribution rights, prepare model tensors, or run a model. The current default experiment accepts short Chinese character/word data; English, mixed, longer or code-like observations are outside that preset's scope.

A submission records what SI inserted, not a gold correction, final document, later host edit or sentence boundary. Default acceptance and auto-generated text can reinforce engine mistakes. Personal-phrase expansions and literal/code entries need separate review; inspect private content and unsuitable material before using it. The archive provides no reliable anonymous-user grouping. Preserve contribution provenance, deduplicate overlapping event UUIDs across repeated exports, review/clean observations and assign disjoint source/input/target groups before training/evaluation. The existing CSV preparation enforces split-overlap checks. No real contribution is collected, uploaded or trained by this implementation.

## Portable JSONL format, version 1

Each line is one JSON object terminated by LF. The first line is a manifest:

```json
{"type":"manifest","format":"si-input-history","version":1,"scope":"all_saved_history","exported_at_unix":1793491200}
```

Entry lines contain exactly:

```json
{"type":"entry","sequence":1,"id":"11111111-1111-4111-8111-111111111111","created_at_unix":1793491200,"input":"nihao","output":"你好","language":"zh-Hans","mixed":false,"reason":"explicitSelection"}
```

`sequence` is the original positive SQLite sequence and must increase, but may have gaps from deletion. UUIDs are canonical uppercase identities, not user/device identifiers. Times are finite Unix seconds, retaining the stored fractional value. Language is `zh-Hans`, `en` or null. `mixed` is boolean and requires Chinese identity when true. Commit reasons are the current `CommitReason` raw values. JSON escaping preserves original input/output, including line breaks, quotes, NUL, casing and normalization forms. No app identifier, document, clipboard, account or device metadata is added.

The last line contains `type: "summary"`, `record_count` and lowercase hexadecimal `sha256`. That hash covers the **exact bytes of every preceding manifest/entry line including its LF**, excluding the summary line itself. No trailing content is permitted. Each object's encoded bytes are bounded to 64 MiB (plus LF); the archive has no total-record/total-file limit. An oversized record fails export without truncation or destination replacement. Swift export streams one record at a time into a 0600 temporary file beside the destination, flushes it, and publishes via atomic rename. Failure preserves the previous destination and removes the temporary file. A snapshot runs on the storage actor in one read transaction; concurrent recording resumes queued writes afterward. Normal termination waits for accepted exports. Receiver tools use new temporary outputs and publish only after validation.

## Checks

```sh
./scripts/test.sh --disable-sandbox --filter InputHistory
python3 -m unittest discover -s Tests/InputHistoryToolsTests -v
```

Synthetic coverage includes a Swift-export → Python-restore → Swift-read round trip, exact Unicode/NUL/source/output bytes, repeated records, file permissions, absence of purpose flags, page/search-independent export, pending save errors, corrupt/truncated/version/duplicate/count/checksum rejection, existing-destination preservation, and more than 5,000 old records. Native save dialogs, cancellation, accessibility and appearance remain manual checks in [TESTING.md](TESTING.md#input-history).
