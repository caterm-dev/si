"""Shared SI dictionary schema, weight contract and semantic comparison."""

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


def domain_reading(text):
    """Return a literal ASCII domain key, without accepting standalone suffixes."""
    if not isinstance(text, str) or not text.isascii():
        return None
    key = text.lower()
    label = r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
    if len(key) <= 253 and re.fullmatch(label + r'(?:\.' + label + r')*\.[a-z]{2,63}', key):
        return key
    return None


def table_for(reading, allow_domain=False):
    if allow_domain and domain_reading(reading) == reading:
        # Keep the shared schema's alphabetic buckets, including numeric host labels.
        initial = next(c for c in reading if c in string.ascii_lowercase)
        return f'tbl_1_{initial}'
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
