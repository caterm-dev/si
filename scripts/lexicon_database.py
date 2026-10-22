"""Shared SI dictionary schema, weight contract and public overlay validation."""

from itertools import zip_longest
import json
from pathlib import Path
import re
import sqlite3
import string

FORMAT_PATH = Path(__file__).resolve().parents[1] / "Data/DictionaryFormat.json"
_format_document = json.loads(FORMAT_PATH.read_text())
FORMAT = {key: _format_document[key] for key in ("schema_version", "weight_unit", "reference_mass")}
INITIALS = string.ascii_lowercase
TABLES = [f"tbl_{bucket}_{initial}" for bucket in [*map(str, range(1, 8)), "others"] for initial in INITIALS]


def table_for(reading):
    if not isinstance(reading, str) or not re.fullmatch(r"[a-z]+(?:'[a-z]+)*", reading):
        raise ValueError("Invalid explicit dictionary reading")
    units = reading.split("'")
    return f"tbl_{len(units) if len(units) <= 7 else 'others'}_{reading[0]}"


def create_schema(connection, unknown_weight=1):
    connection.execute("PRAGMA page_size=4096")
    connection.execute("PRAGMA journal_mode=OFF")
    connection.execute("PRAGMA synchronous=OFF")
    connection.execute("CREATE TABLE dictionary_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    metadata = {key: str(FORMAT[key]) for key in ("schema_version", "weight_unit", "reference_mass")}
    metadata["unknown_weight"] = str(unknown_weight)
    connection.executemany("INSERT INTO dictionary_metadata VALUES (?,?)", sorted(metadata.items()))
    for table in TABLES:
        connection.execute(f"CREATE TABLE {table} (key TEXT, jp TEXT, value TEXT, weight INTEGER NOT NULL)")
        connection.execute(f"CREATE UNIQUE INDEX identity_{table} ON {table}(key,value)")


def finish_schema(connection):
    count = 0
    for table in TABLES:
        connection.execute(f"CREATE INDEX idx_key_{table} ON {table}(key,weight DESC)")
        connection.execute(f"CREATE INDEX idx_jp_{table} ON {table}(jp,weight DESC)")
        connection.execute(f"DROP INDEX identity_{table}")
        count += connection.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
    connection.execute("ANALYZE")
    connection.commit()
    return count


def overlay_entries(path, validate_reading):
    entries = json.loads(path.read_text())
    if not isinstance(entries, list):
        raise ValueError("SI entries must be a list")
    identities = set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) - {"text", "reading", "weight", "exclude", "reason"}:
            raise ValueError("Unsupported SI entry fields")
        for field in ("text", "reading", "reason"):
            if not isinstance(entry.get(field), str) or not entry[field].strip():
                raise ValueError("SI entries require nonempty text, reading and reason")
        if any(ord(c) < 32 or ord(c) == 127 for c in entry["text"]) or len(entry["text"].encode()) > 4096:
            raise ValueError("Invalid SI text")
        validate_reading(entry["text"], entry["reading"])
        identity = (entry["text"], entry["reading"])
        if identity in identities:
            raise ValueError("Duplicate SI text/reading pair")
        identities.add(identity)
        if type(entry.get("exclude", False)) is not bool:
            raise ValueError("SI exclusion must be Boolean")
        if entry.get("exclude", False):
            if "weight" in entry:
                raise ValueError("Excluded SI entries must not specify a weight")
        elif type(entry.get("weight")) is not int or not 0 <= entry["weight"] <= 2**63 - 1:
            raise ValueError("Invalid SI weight")
    return entries


def apply_overlay(connection, entries):
    for entry in entries:
        table = table_for(entry["reading"])
        connection.execute(f"DELETE FROM {table} WHERE key=? AND value=?", (entry["reading"], entry["text"]))
        if not entry.get("exclude", False):
            connection.execute(f"INSERT INTO {table} VALUES (?,?,?,?)", (
                entry["reading"], "".join(s[0] for s in entry["reading"].split("'")), entry["text"], entry["weight"]))


def same_dictionary(expected, actual, tables=TABLES):
    """Compare schema, metadata, ordered rows and integrity across SQLite versions."""
    left = sqlite3.connect(Path(expected).resolve().as_uri() + "?mode=ro&immutable=1", uri=True)
    right = None
    try:
        right = sqlite3.connect(Path(actual).resolve().as_uri() + "?mode=ro&immutable=1", uri=True)
        schema = "SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name"
        if left.execute(schema).fetchall() != right.execute(schema).fetchall():
            return False
        if left.execute("SELECT * FROM dictionary_metadata ORDER BY key").fetchall() != right.execute(
                "SELECT * FROM dictionary_metadata ORDER BY key").fetchall():
            return False
        for table in tables:
            query = f"SELECT rowid,key,jp,value,weight FROM {table} ORDER BY rowid"
            if any(a != b for a, b in zip_longest(left.execute(query), right.execute(query))):
                return False
        return right.execute("PRAGMA integrity_check").fetchone() == ("ok",)
    except sqlite3.DatabaseError:
        return False
    finally:
        left.close()
        if right is not None:
            right.close()
