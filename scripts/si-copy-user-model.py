#!/usr/bin/env python3
"""Copy the installed SI user model into the checkout."""

import argparse
import fcntl
import os
from pathlib import Path
import shutil
import tempfile


MODEL_FILES = ("user.silex", "user.sigram")
SNAPSHOTS = {b"a\n": "snapshot-a", b"b\n": "snapshot-b"}


def copy_user_model(profile: Path, destination: Path) -> None:
    if not (profile / "profile.lock").is_file():
        raise FileNotFoundError("No saved user model in the installed SI profile.")

    with (profile / "profile.lock").open("rb") as lock:
        # Use the same flock as UserModelStore to keep the active pair available
        # during the copy and serialize simultaneous invocations of this script.
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = profile / "current"
        pointer = current.read_bytes() if current.exists() else b"empty\n"
        if pointer == b"empty\n":
            raise FileNotFoundError("No saved user model in the installed SI profile.")
        if pointer not in SNAPSHOTS:
            raise ValueError("Invalid installed SI user model snapshot pointer.")
        snapshot = profile / SNAPSHOTS[pointer]
        if snapshot.is_symlink():
            raise ValueError("The installed SI user model snapshot must be a directory.")

        destination.mkdir(parents=True, exist_ok=True)
        lexicon, grams = (destination / name for name in MODEL_FILES)
        for path in (lexicon, grams):
            if path.is_symlink() or (path.exists() and not path.is_file()):
                raise ValueError(f"Expected a regular destination file at {path}")

        with tempfile.TemporaryDirectory(prefix=".si-user-copy-", dir=destination) as directory:
            staging = Path(directory)
            for name in MODEL_FILES:
                source = snapshot / name
                if source.is_symlink() or not source.is_file():
                    raise FileNotFoundError(f"Missing regular snapshot file {name}")
                copy = staging / name
                shutil.copyfile(source, copy)
                copy.chmod(0o600)

            previous = staging / "previous.silex"
            if lexicon.exists():
                os.link(lexicon, previous)
            os.replace(staging / lexicon.name, lexicon)
            try:
                os.replace(staging / grams.name, grams)
            except (OSError, KeyboardInterrupt):
                if previous.exists():
                    os.replace(previous, lexicon)
                else:
                    lexicon.unlink()
                raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    profile = Path.home() / "Library/Application Support/SI/Personalization/model.si-user"
    destination = Path(__file__).resolve().parents[1] / ".build/si-data"
    try:
        copy_user_model(profile, destination)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")
    print(f"Copied user.silex and user.sigram to {destination}")


if __name__ == "__main__":
    main()
