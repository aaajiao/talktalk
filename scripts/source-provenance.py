#!/usr/bin/env python3
"""Fingerprint local application build inputs; never store source contents or absolute paths.

Capture after build-number reservation, then embed only if the same inputs are still
present after compilation/assembly. Publication compares the signed receipt to the
current clean source tree. Documentation and tests that do not ship are excluded.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RECEIPT = Path("Contents/Resources/build-source.json")
TREES = ("Sources", "Resources", "engine/talktalk_engine", "Driver/Sources", "Driver/Resources",
         "Driver/third_party", "scripts/lib", "scripts/driver", "tools/feedprobe")
FILES = ("Package.swift", "Package.resolved", "Driver/Info.plist.in", "engine/talktalk_engine.py",
         "engine/smoke_engine.py", "engine/requirements-engine.lock", "engine/requirements-build.lock",
         "LICENSE", "THIRD_PARTY_NOTICES.md", "docs/maintenance.md",
         "scripts/build-app.sh", "scripts/build-driver.sh", "scripts/install-engine.sh",
         "scripts/compile-localizations.py", "scripts/gen-pins.sh", "scripts/reserve-app-build.py",
         "scripts/source-provenance.py", "scripts/package-update.py")
REQUIRED = ("Package.swift", "Package.resolved", "scripts/lib/versions.sh")
SKIP_DIRECTORIES = {"__pycache__", ".git", ".build", ".swiftpm", "tests", "Tests"}


def input_files(root):
    root = Path(root).resolve()
    for required in REQUIRED:
        if not (root / required).is_file():
            raise ValueError(f"build input missing: {required}")
    selected = set()
    for name in FILES:
        path = root / name
        if path.exists() or path.is_symlink():
            selected.add(path)
    for name in TREES:
        start = root / name
        if not start.exists():
            continue
        if start.is_symlink():
            raise ValueError(f"build input directory must not be a symlink: {name}")
        for directory, folders, files in os.walk(start, followlinks=False):
            folders[:] = sorted(folder for folder in folders if folder not in SKIP_DIRECTORIES)
            for folder in folders:
                path = Path(directory) / folder
                if path.is_symlink():
                    raise ValueError(f"build input directory must not be a symlink: {path.relative_to(root)}")
            for filename in files:
                if filename == ".DS_Store" or filename.endswith((".pyc", ".pyo")):
                    continue
                selected.add(Path(directory) / filename)
    return sorted(selected, key=lambda path: path.relative_to(root).as_posix())


def fingerprint(root):
    root = Path(root).resolve()
    paths = input_files(root)
    digest = hashlib.sha256()
    for path in paths:
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            raise ValueError(f"build input must not be a symlink: {name}")
        metadata = path.stat()
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError(f"build input must be a regular file: {name}")
        with path.open("rb") as stream:
            content_hash = hashlib.file_digest(stream, "sha256").digest()
        digest.update(name.encode("utf-8") + b"\0")
        digest.update(str(metadata.st_mode & 0o111).encode("ascii") + b"\0")
        digest.update(content_hash)
    return {"schema": 1, "algorithm": "sha256", "source_sha256": digest.hexdigest(), "file_count": len(paths)}


def validate_record(record):
    if (not isinstance(record, dict) or set(record) != {"schema", "algorithm", "source_sha256", "file_count"}
            or type(record["schema"]) is not int or record["schema"] != 1
            or record["algorithm"] != "sha256"
            or not isinstance(record["source_sha256"], str)
            or not re.fullmatch(r"[0-9a-f]{64}", record["source_sha256"])
            or type(record["file_count"]) is not int or record["file_count"] <= 0):
        raise ValueError("invalid build-source receipt; rebuild the application")
    return record


def read_record(path):
    path = Path(path)
    if not path.is_file() or path.is_symlink():
        raise ValueError("build-source receipt missing; rebuild the application")
    return validate_record(json.loads(path.read_text(encoding="utf-8")))


def write_record(path, record):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".build-source-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(json.dumps(validate_record(record), sort_keys=True, indent=2) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def embed_receipt(root, snapshot, app):
    expected = read_record(snapshot)
    if fingerprint(root) != expected:
        raise ValueError("application inputs changed during build; rebuild before publishing")
    write_record(Path(app) / RECEIPT, expected)
    return expected


def verify_receipt(root, app):
    receipt = read_record(Path(app) / RECEIPT)
    if fingerprint(root) != receipt:
        raise ValueError("application source differs from the built bundle; rebuild, check, commit and push again")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("capture", "embed", "verify", "inspect"))
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--snapshot", type=Path)
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    try:
        if args.operation == "capture":
            if args.output is None:
                raise ValueError("capture requires --output")
            result = fingerprint(args.root)
            write_record(args.output, result)
        elif args.operation == "embed":
            if args.snapshot is None or args.app is None:
                raise ValueError("embed requires --snapshot and --app")
            result = embed_receipt(args.root, args.snapshot, args.app)
        elif args.operation == "verify":
            if args.app is None:
                raise ValueError("verify requires --app")
            result = verify_receipt(args.root, args.app)
        else:
            if args.app is None:
                raise ValueError("inspect requires --app")
            result = read_record(args.app / RECEIPT)
    except (OSError, ValueError) as error:
        parser.exit(1, f"build-source: {error}\n")
    print(f"build-source: {result['source_sha256']} ({result['file_count']} inputs)")


if __name__ == "__main__":
    main()
