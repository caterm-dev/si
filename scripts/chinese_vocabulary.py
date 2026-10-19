"""Rime Pinyin data adapter for the shared vocabulary maintenance commands."""

from pathlib import Path
import re

import vocabulary as common

DATA = Path("Data/Chinese")
GENERATED = Path("mac/SI/Core/ChineseLexiconData.swift")
NOTICES = Path("mac/SI/Resources/ChineseVocabularyNotices.txt")
MERGED = DATA / "generated/entries.tsv"
REPORT = DATA / "generated/summary.json"


def han(character):
    value = ord(character)
    return (value == 0x3007 or 0x3400 <= value <= 0x4DBF or 0x4E00 <= value <= 0x9FFF
            or 0xF900 <= value <= 0xFAFF or 0x20000 <= value <= 0x2FA1F or 0x30000 <= value <= 0x323AF)


def identity(text, reading):
    if not isinstance(text, str) or not text or not all(han(c) for c in text):
        raise common.VocabularyError("Chinese entries require Han text: " + repr(text))
    if not isinstance(reading, str):
        raise common.VocabularyError("Pinyin reading must be text")
    normalized = reading.lower().replace("u:", "v").replace("ü", "v")
    syllables = normalized.split(" ")
    if (len(syllables) != len(text) or any(not re.fullmatch(r"[a-z]+", s) for s in syllables)
            or len("".join(syllables)) > 64 or len(text.encode()) > 4096):
        raise common.VocabularyError("Invalid explicit Pinyin reading: " + repr(reading))
    return text, " ".join(syllables)


def parse_snapshot(data, label, allow_empty=False):
    entries = {}
    for number, line in enumerate(data.decode("utf-8").splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        columns = line.split("\t")
        if len(columns) != 3 or not re.fullmatch(r"[0-9]{1,15}", columns[2]):
            raise common.VocabularyError(f"{label}:{number}: expected text, Pinyin and integer weight")
        key = identity(columns[0], columns[1])
        if key in entries:
            raise common.VocabularyError(f"{label}:{number}: duplicate text/reading")
        entries[key] = int(columns[2])
    if not entries and not allow_empty:
        raise common.VocabularyError(label + ": empty Pinyin source")
    return entries


def import_rime(data, minimum_weight=0):
    text = data.decode("utf-8-sig").replace("\r\n", "\n")
    if "\n...\n" not in text:
        raise common.VocabularyError("Rime source lacks a dictionary header terminator")
    header, body = text.split("\n...\n", 1)
    # This adapter requires an explicit text/code/weight table; no automatic pronunciation.
    if "columns:" in header:
        raise common.VocabularyError("Custom Rime columns need an explicit adapter; unannotated tables are unsupported")
    entries, skipped = {}, {"below_minimum_weight": 0, "unsupported_text_or_reading": 0, "duplicates": 0}
    for number, line in enumerate(body.splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        columns = line.split("\t")
        if len(columns) != 3 or not re.fullmatch(r"[0-9]{1,15}", columns[2]):
            raise common.VocabularyError(f"Rime row {number}: missing explicit reading or integer weight")
        weight = int(columns[2])
        if weight < minimum_weight:
            skipped["below_minimum_weight"] += 1
            continue
        try:
            key = identity(columns[0], columns[1])
        except common.VocabularyError:
            skipped["unsupported_text_or_reading"] += 1
            continue
        if key in entries:
            skipped["duplicates"] += 1
        entries[key] = max(weight, entries.get(key, 0))
    if not entries:
        raise common.VocabularyError("Importer produced no supported Chinese entries")
    snapshot = "".join(f"{text}\t{reading}\t{entries[text, reading]}\n" for text, reading in sorted(entries))
    return snapshot.encode(), (header + "\n...\n").encode(), skipped


def configuration(root, pending=None, refreshing=None):
    config, lock = common.configuration(root, pending, refreshing=refreshing, data_dir=DATA)
    for source in config["sources"]:
        if source["weight_kind"] not in ("score", "frequency"):
            raise common.VocabularyError("Unknown Chinese weight kind")
        if source["weight_kind"] == "frequency":
            minimum, maximum = source["score_min"], source["score_max"]
            if type(minimum) is not int or type(maximum) is not int or not 0 <= minimum <= maximum <= 100:
                raise common.VocabularyError("Invalid Chinese score range")
        if "upstream" in source:
            if source["upstream"]["format"] != "rime-pinyin":
                raise common.VocabularyError("Chinese upstream sources must use rime-pinyin")
            weight = source["upstream"].get("minimum_weight", 0)
            if type(weight) is not int or not 0 <= weight < 10**15:
                raise common.VocabularyError("Invalid minimum upstream weight")
    return config, lock


def score_for(weight, source):
    if source["weight_kind"] == "score":
        if not 0 <= weight <= 200:
            raise common.VocabularyError("SI Pinyin scores must be in 0...200")
        return weight
    # Integer decimal magnitude: stable across machines, bounded below exact English matches.
    return min(source["score_max"], source["score_min"] + len(str(max(1, weight))) - 1)


def compile_vocabulary(root, pending=None):
    pending = pending or {}
    config, lock = configuration(root, pending)
    merged, counts, original = {}, {}, {}
    for source in sorted(config["sources"], key=lambda s: s["priority"]):
        rows = parse_snapshot(common.read_bytes(root, source["path"], pending), source["id"], source.get("allow_empty", False))
        counts[source["id"]] = len(rows)
        for key, weight in rows.items():
            score = score_for(weight, source)
            origins = merged.get(key, {}).get("sources", [])
            merged[key] = {"score": score, "sources": origins + [source["id"]], "weight": weight}
            if source["id"] == "si-original":
                original[key] = score
    overrides = common.read_json(root, DATA / "overrides.json", pending)
    if overrides.get("schema_version") != 1:
        raise common.VocabularyError("Unsupported Chinese overrides schema")
    seen, inactive = set(), []
    for rule in overrides["rules"]:
        key = identity(rule["text"], rule["reading"])
        if key in seen or not isinstance(rule.get("reason"), str) or not rule["reason"].strip():
            raise common.VocabularyError("Chinese overrides need a unique text/reading and reason")
        seen.add(key)
        if rule["action"] not in ("exclude", "replace"):
            raise common.VocabularyError("Unknown Chinese override action")
        old = merged.pop(key, None)
        if old is None:
            inactive.append({"text": key[0], "reading": key[1]})
        if rule["action"] == "replace":
            replacement = rule["replacement"]
            new_key = identity(replacement["text"], replacement["reading"])
            score = replacement["score"]
            if type(score) is not int or not 0 <= score <= 200:
                raise common.VocabularyError("Invalid Chinese override score")
            origins = merged.get(new_key, old or {}).get("sources", [])
            merged[new_key] = {"score": score, "sources": list(dict.fromkeys(origins + ["si-overrides"])), "weight": score}
    for rule in overrides["rules"]:
        if rule["action"] == "exclude":
            merged.pop(identity(rule["text"], rule["reading"]), None)
    if not merged:
        raise common.VocabularyError("Merged Chinese vocabulary is empty")
    keys = sorted(merged, key=lambda key: (key[1].replace(" ", ""), key[1], key[0]))
    words = "".join(f"{text}\t{reading}\t{merged[text, reading]['score']}\n" for text, reading in keys)
    originals = "".join(f"{text}\t{reading}\t{score}\n" for (text, reading), score in sorted(original.items()))
    swift = '''// Generated by scripts/vocabulary.py --language chinese. Do not edit.
// Sources, selection and licenses: Data/Chinese/ and ChineseVocabularyNotices.txt.
enum ChineseLexiconData {
    static let entries = parse(data)
    static let originalEntries = parse(originalData)

    private static func parse(_ data: String) -> [PinyinLexiconEntry] {
        data.split(separator: "\\n").map { line in
            let fields = line.split(separator: "\\t")
            return PinyinLexiconEntry(syllables: fields[1].split(separator: " ").map(String.init),
                                     text: String(fields[0]), score: Int(fields[2])!)
        }
    }

    private static let data = """
'''+"".join("    "+line+"\n" for line in words.splitlines())+'''    """
    private static let originalData = """
'''+"".join("    "+line+"\n" for line in originals.splitlines())+'''    """
}
'''
    notices = ["SI Chinese vocabulary notices", "Generated from pinned, locally processed source data. No user input is included."]
    for source in config["sources"]:
        revision = lock["sources"].get(source["id"], {}).get("revision", "repository version")
        notice = f"{source['id']}\nOrigin: {source['origin']}\nRevision: {revision}\nLicense: {source['license_id']}\n\n"
        notice += common.read_bytes(root, source["license_file"], pending).decode().rstrip()
        if source.get("attribution_file"):
            notice += "\n\nOriginal upstream header (including data origins):\n" + common.read_bytes(root, source["attribution_file"], pending).decode().rstrip()
        notices.append(notice)
    for notice in config.get("additional_notices", []):
        content = common.read_bytes(root, notice["path"], pending)
        if common.digest(content) != notice["sha256"]:
            raise common.VocabularyError("Additional Chinese notice checksum mismatch")
        notices.append(notice["origin"] + "\n\n" + content.decode().rstrip())
    summary = {"schema_version": 1, "merged_entries": len(keys), "distinct_texts": len({text for text, _ in keys}),
               "source_entries": counts, "inactive_overrides": inactive, "entries_sha256": common.digest(words.encode()),
               "inputs_sha256": common.digest(common.json_bytes(config) + common.json_bytes(lock) + common.json_bytes(overrides)
                    + b"".join(common.read_bytes(root, s["path"], pending) + common.read_bytes(root, s["license_file"], pending)
                               + (common.read_bytes(root, s["attribution_file"], pending) if s.get("attribution_file") else b"")
                               for s in config["sources"]))}
    table = "# text\treading\tscore\tsources\n"+"".join(
        f"{text}\t{reading}\t{merged[text, reading]['score']}\t{','.join(merged[text, reading]['sources'])}\n" for text, reading in keys)
    return {GENERATED: swift.encode(), MERGED: table.encode(), REPORT: common.json_bytes(summary),
            NOTICES: ("\n\n".join(notices)+"\n").encode()}, summary


def refresh(root, source_id, revision=None, latest=False, accept_license_change=False, download=common.fetch):
    config = common.read_json(root, DATA / "sources.json", {})
    selected = [s for s in config["sources"] if "upstream" in s and (s["id"] == source_id or s.get("group") == source_id)]
    if not selected:
        raise common.VocabularyError("Not a Chinese upstream source or group: " + source_id)
    # Stage the complete group and validate all sources before writing any changed file.
    lock = common.read_json(root, DATA / "sources.lock.json", {})
    pending, revision_for_repo = {}, {}
    for source in selected:
        upstream = source["upstream"]
        current = lock["sources"].get(source["id"], {})
        if not current and not accept_license_change:
            raise common.VocabularyError("First Chinese import requires license review and --accept-license-change")
        key = (upstream["repository"], upstream["ref"])
        if latest and key not in revision_for_repo:
            revision_for_repo[key] = common.latest_revision(source, download)
        pin = revision_for_repo[key] if latest else revision or current.get("revision", "")
        if not common.REVISION.fullmatch(pin):
            raise common.VocabularyError("Use a full 40-character commit SHA")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", upstream["repository"]):
            raise common.VocabularyError("Invalid GitHub repository")
        base = f"https://raw.githubusercontent.com/{upstream['repository']}/{pin}/"
        raw = download(base + upstream["path"])
        license_data = download(base + upstream["license_path"])
        if pin == current.get("revision") and common.digest(raw) != current["download_sha256"]:
            raise common.VocabularyError("Pinned Chinese source checksum changed")
        if common.digest(license_data) != current.get("license_sha256") and not accept_license_change:
            raise common.VocabularyError("Chinese upstream license changed; review before --accept-license-change")
        snapshot, header, filtering = import_rime(raw, upstream.get("minimum_weight", 0))
        count = len(snapshot.splitlines())
        if not upstream["minimum_words"] <= count <= upstream["maximum_words"]:
            raise common.VocabularyError(f"Unexpected imported Chinese entry count: {count}")
        lock["sources"][source["id"]] = {
            "revision": pin, "upstream": upstream, "download_sha256": common.digest(raw),
            "snapshot_sha256": common.digest(snapshot), "license_sha256": common.digest(license_data),
            "attribution_sha256": common.digest(header), "filtering": filtering,
        }
        pending[Path(source["path"])] = snapshot
        pending[Path(source["license_file"])] = license_data
        pending[Path(source["attribution_file"])] = header
    pending[DATA / "sources.lock.json"] = common.json_bytes(lock)
    outputs, summary = compile_vocabulary(root, pending)
    common.write_outputs(root, {**pending, **outputs})
    return summary


def execute(root, args):
    if args.command in ("build", "stats"):
        outputs, summary = compile_vocabulary(root)
        if args.command == "build":
            common.write_outputs(root, outputs, args.check)
        print(common.json_bytes(summary).decode(), end="")
    elif args.command == "refresh":
        print(common.json_bytes(refresh(root, args.source, args.revision, args.latest, args.accept_license_change)).decode(), end="")
    elif args.command == "audit":
        result = common.json_bytes(common.audit(root, data_dir=DATA, language="chinese"))
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_bytes(result)
        print(result.decode(), end="")
    elif args.command == "explain":
        if not args.word or not all(han(c) for c in args.word):
            raise common.VocabularyError("Chinese explain expects Han text")
        config, _ = configuration(root)
        rows, _ = compile_vocabulary(root)
        origins = [{"source": s["id"], "reading": reading, "weight": weight, "score": score_for(weight, s)}
                   for s in config["sources"]
                   for (text, reading), weight in parse_snapshot(common.read_bytes(root, s["path"], {}), s["id"], s.get("allow_empty", False)).items()
                   if text == args.word]
        merged = [line for line in rows[MERGED].decode().splitlines()[1:] if line.split("\t")[0] == args.word]
        print(common.json_bytes({"query": args.word, "sources": origins, "merged": merged}).decode(), end="")
