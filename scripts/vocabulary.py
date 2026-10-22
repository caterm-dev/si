#!/usr/bin/env python3
"""Maintain SI's checked-in vocabularies (English by default). Python 3.9+, standard library only."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from urllib.error import HTTPError


ROOT = Path(__file__).resolve().parents[1]
DATA = Path("Data/English")
GENERATED = Path("mac/SI/Core/EnglishLexiconData.swift")
NOTICES = Path("mac/SI/Resources/EnglishVocabularyNotices.txt")
REPORT = DATA / "generated/summary.json"
MERGED = DATA / "generated/words.tsv"
WORD = re.compile(r"[A-Za-z]{1,64}\Z")
REVISION = re.compile(r"[0-9a-f]{40}\Z")
MAX_DOWNLOAD = 32 * 1024 * 1024


class VocabularyError(ValueError):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def read_json(root, path, pending):
    return json.loads(read_bytes(root, path, pending))


def read_bytes(root, path, pending):
    path = Path(path)
    if path.is_absolute() or ".." in path.parts:
        raise VocabularyError("Paths must stay inside the repository: " + str(path))
    return pending[path] if path in pending else (root / path).read_bytes()


def validate_word(word):
    if not isinstance(word, str) or not WORD.fullmatch(word):
        raise VocabularyError("Expected 1–64 ASCII letters: " + repr(word))
    return word.lower()


def parse_words(data, label):
    words = {}
    for number, line in enumerate(data.decode("utf-8").splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        key = validate_word(line)
        if key in words:
            raise VocabularyError(f"{label}:{number}: duplicate spelling {line!r}")
        words[key] = line
    if not words:
        raise VocabularyError(label + ": empty source")
    return words


def configuration(root, pending=None, refreshing=None, data_dir=DATA):
    pending = pending or {}
    config = read_json(root, data_dir / "sources.json", pending)
    lock = read_json(root, data_dir / "sources.lock.json", pending)
    if config.get("schema_version") != 1 or lock.get("schema_version") != 1:
        raise VocabularyError("Unsupported source/lock schema")
    ids, priorities = set(), set()
    for source in config["sources"]:
        sid = source["id"]
        if not re.fullmatch(r"[a-z][a-z0-9-]*", sid) or sid in ids:
            raise VocabularyError("Invalid or duplicate source ID: " + sid)
        if type(source["priority"]) is not int or source["priority"] in priorities:
            raise VocabularyError("Source priorities must be distinct integers")
        score = source.get("completion_score", 85)
        if type(score) is not int or not 0 <= score <= 85:
            raise VocabularyError(sid + ": completion_score must be in 0...85")
        ids.add(sid)
        priorities.add(source["priority"])
        for field in ("path", "license_file", "license_id", "origin"):
            if not source.get(field):
                raise VocabularyError(f"{sid}: missing {field}")
        if sid != refreshing and not read_bytes(root, source["license_file"], pending).strip():
            raise VocabularyError(sid + ": empty license")
        if "upstream" in source:
            upstream = source["upstream"]
            if upstream["format"] not in ("scowl", "wordlist", "cspell", "rime", "rime-pinyin"):
                raise VocabularyError(sid + ": unsupported importer")
            if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", upstream["repository"]):
                raise VocabularyError(sid + ": invalid GitHub repository")
            minimum, maximum = upstream["minimum_words"], upstream["maximum_words"]
            if type(minimum) is not int or type(maximum) is not int or not 1 <= minimum <= maximum <= (2000000 if upstream["format"] == "rime-pinyin" else 200000):
                raise VocabularyError(sid + ": invalid word-count bounds")
            if type(upstream.get("minimum_length", 2)) is not int or not (1 if upstream["format"] == "rime-pinyin" else 2) <= upstream.get("minimum_length", 2) <= 64:
                raise VocabularyError(sid + ": invalid minimum_length")
            if sid == refreshing:
                continue
            item = lock["sources"].get(sid, {})
            if not REVISION.fullmatch(item.get("revision", "")):
                raise VocabularyError(sid + ": missing pinned revision")
            if item.get("upstream") != source["upstream"]:
                raise VocabularyError(sid + ": import settings changed; run refresh")
            paths = [("snapshot_sha256", source["path"]), ("license_sha256", source["license_file"])]
            if source.get("attribution_file"):
                paths.append(("attribution_sha256", source["attribution_file"]))
            for field, path in paths:
                if digest(read_bytes(root, path, pending)) != item.get(field):
                    raise VocabularyError(f"{sid}: {field} mismatch; use refresh, not snapshot edits")
    upstream_ids = {s["id"] for s in config["sources"] if "upstream" in s}
    if set(lock["sources"]) - upstream_ids or upstream_ids - set(lock["sources"]) - {refreshing}:
        raise VocabularyError("Lock entries must match upstream sources")
    return config, lock


def compile_vocabulary(root, pending=None):
    pending = pending or {}
    config, lock = configuration(root, pending)
    merged, counts = {}, {}
    for source in sorted(config["sources"], key=lambda s: s["priority"]):
        words = parse_words(read_bytes(root, source["path"], pending), source["id"])
        counts[source["id"]] = len(words)
        for key, word in words.items():
            origins = merged[key]["sources"] if key in merged else []
            merged[key] = {"word": word, "sources": origins + [source["id"]],
                           "completion_score": source.get("completion_score", 85)}
    overrides = read_json(root, DATA / "overrides.json", pending)
    if overrides.get("schema_version") != 1:
        raise VocabularyError("Unsupported overrides schema")
    seen, inactive = set(), []
    for rule in overrides["rules"]:
        key = validate_word(rule["word"])
        if key in seen or not isinstance(rule.get("reason"), str) or not rule["reason"].strip():
            raise VocabularyError("Override needs a unique word and a reason: " + rule["word"])
        seen.add(key)
        if rule.get("action") not in ("exclude", "replace"):
            raise VocabularyError("Unknown override action")
        old = merged.pop(key, None)
        if old is None:
            inactive.append(rule["word"])
        if rule["action"] == "replace":
            replacement = rule["replacement"]
            replacement_key = validate_word(replacement)
            origins = merged.get(replacement_key, old or {}).get("sources", [])
            merged[replacement_key] = {"word": replacement, "sources": list(dict.fromkeys(origins + ["si-overrides"])),
                                       "completion_score": (old or {}).get("completion_score", 85)}
    # Exclusions win even when another replacement targets the same word.
    for rule in overrides["rules"]:
        if rule["action"] == "exclude":
            merged.pop(rule["word"].lower(), None)
    if not merged:
        raise VocabularyError("Merged vocabulary is empty")
    rows = [merged[key] for key in sorted(merged)]
    words_data = ("\n".join(row["word"] for row in rows) + "\n").encode()
    score_rows = [row for row in rows if row["completion_score"] != 75]
    score_literal = ("[\n" + "".join(
        f'        "{row["word"].lower()}": {row["completion_score"]},\n' for row in score_rows
    ) + "    ]") if score_rows else "[:]"
    swift = (
        "// Generated by scripts/vocabulary.py. Do not edit.\n"
        "// Source versions and licenses: Data/English/ and EnglishVocabularyNotices.txt.\n"
        "enum EnglishLexiconData {\n"
        "    static let words: [String] = \"\"\"\n"
        + "".join("    " + row["word"] + "\n" for row in rows)
        + '    """.split(separator: "\\n").map(String.init)\n'
        + '    // Legacy source metadata; runtime ranking uses EnglishFrequencyData.\n'
        + '    static let completionScores: [String: Int] = ' + score_literal + '\n}\n'
    ).encode()
    notice_parts = [
        "SI English vocabulary notices",
        "Generated from Data/English/sources.json. Local processing; no user input is included.",
    ]
    for source in config["sources"]:
        revision = lock["sources"].get(source["id"], {}).get("revision", "repository version")
        notice_parts.append(
            f'{source["id"]}\nOrigin: {source["origin"]}\nRevision: {revision}\n'
            f'License: {source["license_id"]}\n\n'
            + read_bytes(root, source["license_file"], pending).decode().rstrip()
        )
    summary = {
        "schema_version": 1,
        "merged_words": len(rows),
        "source_words": counts,
        "overlapping_spellings": sum(len(row["sources"]) > 1 for row in rows),
        "inactive_overrides": inactive,
        "words_sha256": digest(words_data),
        "inputs_sha256": digest(
            json_bytes(config) + json_bytes(lock) + json_bytes(overrides)
            + b"".join(read_bytes(root, s["path"], pending)
                       + read_bytes(root, s["license_file"], pending) for s in config["sources"])
        ),
    }
    outputs = {
        GENERATED: swift,
        MERGED: ("# word\tsources (last source supplies preferred casing)\tcompletion_score\n"
                 + "".join(row["word"] + "\t" + ",".join(row["sources"]) + "\t" + str(row["completion_score"]) + "\n" for row in rows)).encode(),
        REPORT: json_bytes(summary),
        NOTICES: ("\n\n".join(notice_parts) + "\n").encode(),
    }
    return outputs, summary


def write_outputs(root, outputs, check=False):
    changed = [path for path, data in outputs.items()
               if not (root / path).exists() or (root / path).read_bytes() != data]
    if check:
        if changed:
            raise VocabularyError("Stale generated files; run build:\n" + "\n".join(map(str, changed)))
        return
    # Validate and render everything before replacing any file.
    for path in changed:
        destination = root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(outputs[path])
        try:
            temporary.chmod(0o644)
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)


def fetch(url):
    if not url.startswith("https://"):
        raise VocabularyError("Only HTTPS sources are supported")
    headers = {"User-Agent": "SI-vocabulary-maintenance"}
    if url.startswith("https://api.github.com/") and os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        if not response.url.startswith("https://"):
            raise VocabularyError("Upstream redirected away from HTTPS")
        data = response.read(MAX_DOWNLOAD + 1)
    if len(data) > MAX_DOWNLOAD:
        raise VocabularyError("Upstream download exceeds 32 MiB")
    return data


def latest_revision(source, download=fetch):
    upstream = source["upstream"]
    repo, ref = upstream["repository"], upstream["ref"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise VocabularyError("Invalid GitHub repository")
    from urllib.parse import quote
    try:
        result = json.loads(download(f"https://api.github.com/repos/{repo}/commits/{quote(ref, safe='')}"))
        revision = result["sha"]
    except HTTPError as error:
        if error.code not in (403, 429):
            raise
        # Public Git ref discovery remains available when shared API quotas are exhausted.
        advertisement = download(f"https://github.com/{repo}.git/info/refs?service=git-upload-pack")
        refs = {name.decode(): sha.decode() for sha, name in re.findall(
            rb"([0-9a-f]{40}) (refs/(?:heads|tags)/[^\x00\n ]+)", advertisement
        )}
        revision = next((refs[name] for name in ("refs/heads/" + ref, "refs/tags/" + ref + "^{}",
                                                 "refs/tags/" + ref) if name in refs), "")
    if not REVISION.fullmatch(revision):
        raise VocabularyError("Invalid upstream revision")
    return revision


def import_words(data, kind, minimum_length=2):
    text = data.decode("utf-8")
    words, skipped, collapsed = {}, 0, 0
    if kind == "rime":
        if "\n...\n" not in text:
            raise VocabularyError("Rime source lacks a dictionary header terminator")
        text = text.split("\n...\n", 1)[1]
    elif kind not in ("wordlist", "cspell"):
        raise VocabularyError("Unsupported text importer: " + kind)
    inline_comments = 0
    for line in text.splitlines():
        if kind == "cspell":
            # Only whitespace-delimited annotations are comments. C#, foo#bar and
            # compound/suggestion syntax remain unsupported rather than rewritten.
            parts = re.split(r"\s+#", line, maxsplit=1)
            line = parts[0].strip()
            inline_comments += len(parts) - 1
        if not line or line.startswith("#"):
            continue
        columns = [line] if kind == "cspell" else line.split("\t")
        word = columns[0]
        if kind == "rime" and len(columns) >= 2 and columns[1].lower() != word.lower():
            skipped += 1
            continue
        if not WORD.fullmatch(word) or len(word) < minimum_length:
            skipped += 1
            continue
        key = word.lower()
        if key in words:
            collapsed += 1
            # Prefer ordinary lowercase over a proper-name/capitalization variant.
            word = min((words[key], word), key=lambda w: (w != w.lower(), w))
        words[key] = word
    if not words:
        raise VocabularyError("Importer produced no supported words")
    filtering = {
        "unsupported_rows": skipped, "collapsed_case_variants": collapsed,
    }
    if kind == "cspell":
        filtering["inline_comments_removed"] = inline_comments
    return ("\n".join(words[key] for key in sorted(words)) + "\n").encode(), filtering


def scowl_export(archive, size, expected_license=None, accept_license_change=False):
    if type(size) is not int or not 35 <= size <= 60:
        raise VocabularyError("SCOWL size must be between 35 and 60")
    with tempfile.TemporaryDirectory(prefix="si-scowl-") as directory:
        destination = Path(directory)
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as bundle:
            members = bundle.getmembers()
            if len(members) > 10000 or sum(m.size for m in members) > 128 * 1024 * 1024:
                raise VocabularyError("SCOWL archive is too large")
            regular_members = []
            for member in members:
                path = Path(member.name)
                if path.is_absolute() or ".." in path.parts:
                    raise VocabularyError("Unsafe SCOWL archive member")
                if member.issym() or member.islnk():
                    continue  # Optional PostgreSQL source links are not needed by the exporter.
                if not (member.isfile() or member.isdir()):
                    raise VocabularyError("Unsafe SCOWL archive member")
                regular_members.append(member)
            bundle.extractall(destination, members=regular_members)
        directories = list(destination.iterdir())
        if len(directories) != 1 or not directories[0].is_dir():
            raise VocabularyError("Unexpected SCOWL archive layout")
        upstream = directories[0]
        license_data = (upstream / "Copyright").read_bytes()
        if expected_license and digest(license_data) != expected_license and not accept_license_change:
            raise VocabularyError("Upstream license changed; inspect its pinned source and rerun with --accept-license-change")
        # This is a maintainer-only command, never invoked by the app or scheduled audit.
        for command in ([sys.executable, "combine.py", "create-db", "scowl.db"],
                        [sys.executable, "scowl", "word-list", str(size), "A", "1",
                         "--wo-poses=abbr", "--categories=", "--pos-classes="]):
            result = subprocess.run(command, cwd=upstream, capture_output=True, timeout=300, check=True)
        return result.stdout, license_data


def refresh(root, source_id, revision=None, latest=False, accept_license_change=False, download=fetch):
    config, lock = configuration(root, refreshing=source_id)
    source = next((s for s in config["sources"] if s["id"] == source_id), None)
    if source is None or "upstream" not in source:
        raise VocabularyError("Not an upstream source: " + source_id)
    current = lock["sources"].get(source_id, {})
    if not current and not accept_license_change:
        raise VocabularyError("First import requires license review and --accept-license-change")
    revision = latest_revision(source, download) if latest else revision or current.get("revision", "")
    if not REVISION.fullmatch(revision):
        raise VocabularyError("Use a full 40-character commit SHA")
    upstream = source["upstream"]
    repo = upstream["repository"]
    if upstream["format"] == "scowl":
        if repo != "en-wl/wordlist":
            raise VocabularyError("The SCOWL exporter is restricted to en-wl/wordlist")
        raw = download(f"https://codeload.github.com/{repo}/tar.gz/{revision}")
        # A pinned re-fetch must reproduce the recorded download exactly.
        if revision == current.get("revision") and digest(raw) != current["download_sha256"]:
            raise VocabularyError("Pinned upstream download checksum changed")
        words, license_data = scowl_export(raw, upstream["size"], current.get("license_sha256"), accept_license_change)
        kind = "wordlist"
    else:
        base = f"https://raw.githubusercontent.com/{repo}/{revision}/"
        raw = download(base + upstream["path"])
        license_data = download(base + upstream["license_path"])
        words, kind = raw, upstream["format"]
        if revision == current.get("revision") and digest(raw) != current["download_sha256"]:
            raise VocabularyError("Pinned upstream download checksum changed")
    if digest(license_data) != current.get("license_sha256") and not accept_license_change:
        raise VocabularyError("Upstream license changed; inspect its pinned source and rerun with --accept-license-change")
    snapshot, filtering = import_words(words, kind, upstream.get("minimum_length", 2))
    count = len(snapshot.splitlines())
    if count < upstream["minimum_words"] or count > upstream["maximum_words"]:
        raise VocabularyError(f"Unexpected imported size: {count}; inspect the source before changing its bounds")
    lock["sources"][source_id] = {
        "revision": revision, "download_sha256": digest(raw),
        "snapshot_sha256": digest(snapshot), "license_sha256": digest(license_data),
        "filtering": filtering, "upstream": upstream,
    }
    pending = {
        Path(source["path"]): snapshot,
        Path(source["license_file"]): license_data,
        DATA / "sources.lock.json": json_bytes(lock),
    }
    outputs, summary = compile_vocabulary(root, pending)
    write_outputs(root, {**pending, **outputs})
    return summary


def audit(root, download=fetch, data_dir=DATA):
    config, lock = configuration(root, data_dir=data_dir)
    results, revisions = [], {}
    for source in config["sources"]:
        if "upstream" not in source:
            continue
        current = lock["sources"][source["id"]]["revision"]
        key = (source["upstream"]["repository"], source["upstream"]["ref"])
        if key not in revisions:
            revisions[key] = latest_revision(source, download)
        latest = revisions[key]
        results.append({
            "source": source["id"], "pinned_revision": current, "latest_revision": latest,
            "update_available": current != latest,
            "compare_url": f'https://github.com/{source["upstream"]["repository"]}/compare/{current}...{latest}',
            "refresh_command": f"python3 scripts/vocabulary.py refresh {source['id']} --revision {latest}",
        })
    return {"schema_version": 1, "sources": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--language", choices=("english",), default="english")
    sub = parser.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build", help="Validate and generate the unified vocabulary, offline")
    build.add_argument("--check", action="store_true")
    sub.add_parser("stats", help="Show source and merged counts, offline")
    explain = sub.add_parser("explain", help="Show a word's sources and local overrides, offline")
    explain.add_argument("word")
    update = sub.add_parser("refresh", help="Download and import an upstream source")
    update.add_argument("source")
    choice = update.add_mutually_exclusive_group()
    choice.add_argument("--revision")
    choice.add_argument("--latest", action="store_true")
    update.add_argument("--accept-license-change", action="store_true")
    check = sub.add_parser("audit", help="Check upstream revisions without changing vocabulary")
    check.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        if args.command in ("build", "stats"):
            outputs, summary = compile_vocabulary(ROOT)
            if args.command == "build":
                write_outputs(ROOT, outputs, args.check)
            print(json_bytes(summary).decode(), end="")
        elif args.command == "refresh":
            print(json_bytes(refresh(ROOT, args.source, args.revision, args.latest,
                                     args.accept_license_change)).decode(), end="")
        elif args.command == "audit":
            report = json_bytes(audit(ROOT))
            if args.report:
                args.report.parent.mkdir(parents=True, exist_ok=True)
                args.report.write_bytes(report)
            print(report.decode(), end="")
        elif args.command == "explain":
            key = validate_word(args.word)
            config, _ = configuration(ROOT)
            outputs, _ = compile_vocabulary(ROOT)
            sources = [
                {"source": s["id"], "word": words[key], "origin": s["origin"]}
                for s in config["sources"]
                for words in [parse_words(read_bytes(ROOT, s["path"], {}), s["id"])] if key in words
            ]
            final = next((line for line in outputs[MERGED].decode().splitlines()[1:]
                          if line.split("\t")[0].lower() == key), None)
            rules = [r for r in read_json(ROOT, DATA / "overrides.json", {})["rules"]
                     if r["word"].lower() == key or r.get("replacement", "").lower() == key]
            print(json_bytes({"query": args.word, "sources": sources, "overrides": rules,
                              "merged": final}).decode(), end="")
    except (VocabularyError, OSError, KeyError, TypeError, json.JSONDecodeError,
            subprocess.SubprocessError, tarfile.TarError, UnicodeError) as error:
        parser.exit(1, f"Vocabulary error: {error}\n")


if __name__ == "__main__":
    sys.modules.setdefault("vocabulary", sys.modules[__name__])
    main()
