#!/usr/bin/env python3
"""Reserve a build number under build-app.sh's package lock; never build or install anything.

Only TT_APP_BUILD is edited. The manual app version and all engine/model/driver pins stay
unchanged. Failed builds retain their reservation. Explicit --app-bundle paths replace the
standard installed-app search (useful for custom install locations and isolated fixtures).
"""

import argparse
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile


def reserve(root: Path, installed_bundles: list[Path]) -> tuple[str, int]:
    versions = root / "scripts/lib/versions.sh"
    original = versions.read_text(encoding="utf-8")
    # Check every generated output before regenerating any of them.
    generator = root / "scripts/gen-pins.sh"
    subprocess.run([str(generator), "--check"], check=True, stdout=sys.stderr)
    version_matches = list(re.finditer(r'^TT_APP_VERSION="([^"\r\n]+)"\s*$', original, re.MULTILINE))
    build_matches = list(re.finditer(r'^(TT_APP_BUILD=")([0-9]+)("[^\r\n]*)$', original, re.MULTILINE))
    if len(version_matches) != 1 or len(build_matches) != 1:
        raise ValueError("versions.sh needs one quoted TT_APP_VERSION and one integer TT_APP_BUILD")
    version = version_matches[0].group(1)
    match = build_matches[0]
    highest = int(match.group(2))
    bundles = [root / "build/TalkTalk.app", root / "build/TalkTalk-Dev.app", *installed_bundles]
    for bundle in bundles:
        metadata = bundle / "Contents/Info.plist"
        if not metadata.exists():
            continue
        with metadata.open("rb") as stream:
            info = plistlib.load(stream)
        if info.get("CFBundleIdentifier") not in {"com.aaajiao.talktalk", "com.aaajiao.talktalk.dev"}:
            continue
        if info.get("CFBundleShortVersionString") != version:
            continue
        candidate = str(info.get("CFBundleVersion", ""))
        if not re.fullmatch(r"[0-9]+", candidate):
            raise ValueError(f"cannot compare build number in {metadata}: {candidate!r}")
        highest = max(highest, int(candidate))
    next_build = highest + 1
    updated = original[:match.start(2)] + str(next_build) + original[match.end(2):]
    if versions.read_text(encoding="utf-8") != original:
        raise ValueError("versions.sh changed during reservation; retry after checking the generated pins")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=versions.parent,
                                         prefix=".versions-", delete=False) as stream:
            temporary = Path(stream.name)
            os.fchmod(stream.fileno(), stat.S_IMODE(versions.stat().st_mode))
            stream.write(updated)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, versions)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    # Deliberately no rollback: even a generation/compile/sign/smoke failure consumes this ID.
    subprocess.run([str(generator)], check=True, stdout=sys.stderr)
    subprocess.run([str(generator), "--check"], check=True, stdout=sys.stderr)
    return version, next_build


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-bundle", action="append", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    installed = args.app_bundle
    if installed is None:
        installed = [directory / name for directory in (Path("/Applications"), Path.home() / "Applications")
                     for name in ("TalkTalk.app", "TalkTalk-Dev.app")]
    try:
        version, number = reserve(root, installed)
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f"reserve-app-build: {error}", file=sys.stderr)
        return 1
    print(f"reserved TalkTalk {version} ({number})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
