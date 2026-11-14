#!/usr/bin/env python3
"""Publish one checked, committed TalkTalk release without replacing existing assets.

Consumes an already-built release bundle. Packaging signs its archive and appcast with
Sparkle's existing Keychain key. A GitHub draft remains unpublished until every uploaded
asset's SHA-256 and size match the local files. Never exports a signing key.
"""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

REPOSITORY = "aaajiao/talktalk"
REMOTE = "origin"
BRANCH = "main"

_provenance_spec = importlib.util.spec_from_file_location("talktalk_build_source", Path(__file__).with_name("source-provenance.py"))
provenance = importlib.util.module_from_spec(_provenance_spec)
_provenance_spec.loader.exec_module(provenance)


class ReleaseError(RuntimeError):
    pass


def command(root, arguments, runner=subprocess.run, *, check=True):
    return runner(arguments, cwd=root, check=check, capture_output=True, text=True)


def read_identity(root, app):
    source = (root / "scripts/lib/versions.sh").read_text(encoding="utf-8")
    values = {}
    for key in ("TT_APP_VERSION", "TT_APP_BUILD"):
        matches = re.findall(rf'^{key}="([^"\r\n]+)"\s*$', source, re.MULTILINE)
        if len(matches) != 1:
            raise ReleaseError(f"versions.sh needs exactly one {key}")
        values[key] = matches[0]
    version, build = values["TT_APP_VERSION"], values["TT_APP_BUILD"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ReleaseError("Only stable three-part application versions can be published")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ReleaseError("Application build must be a positive integer")
    with (app / "Contents/Info.plist").open("rb") as stream:
        metadata = plistlib.load(stream)
    if (metadata.get("CFBundleIdentifier"), metadata.get("CFBundleShortVersionString"),
            metadata.get("CFBundleVersion")) != ("com.aaajiao.talktalk", version, build):
        raise ReleaseError("The release bundle identity does not match versions.sh; build it again")
    return version, build


def assert_clean_main(root, runner):
    branch = command(root, ["git", "symbolic-ref", "--quiet", "--short", "HEAD"], runner).stdout.strip()
    if branch != BRANCH:
        raise ReleaseError("Publish only from the main branch")
    if command(root, ["git", "status", "--porcelain", "--untracked-files=all"], runner).stdout.strip():
        raise ReleaseError("Commit and push all source changes before publishing")
    remote = command(root, ["git", "remote", "get-url", REMOTE], runner).stdout.strip()
    allowed = {f"https://github.com/{REPOSITORY}.git", f"https://github.com/{REPOSITORY}",
               f"git@github.com:{REPOSITORY}.git", f"ssh://git@github.com/{REPOSITORY}.git"}
    if remote not in allowed:
        raise ReleaseError(f"origin must name github.com/{REPOSITORY}")
    head = command(root, ["git", "rev-parse", "HEAD"], runner).stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ReleaseError("Cannot determine a full source commit")
    assert_remote_main(root, head, runner)
    return head


def assert_remote_main(root, head, runner):
    remote = command(root, ["git", "ls-remote", REMOTE, f"refs/heads/{BRANCH}"], runner).stdout.strip()
    if remote != f"{head}\trefs/heads/{BRANCH}":
        raise ReleaseError("Local HEAD must equal origin/main; push or reconcile changes first")


def assert_unused_release(root, tag, runner):
    local = command(root, ["git", "show-ref", "--verify", "--quiet", f"refs/tags/{tag}"], runner, check=False)
    if local.returncode == 0:
        raise ReleaseError(f"Tag {tag} already exists locally; published versions are never overwritten")
    if local.returncode != 1:
        raise ReleaseError("Could not check the local release tag")
    if command(root, ["git", "ls-remote", REMOTE, f"refs/tags/{tag}"], runner).stdout.strip():
        raise ReleaseError(f"Tag {tag} already exists remotely")
    response = command(root, ["gh", "api", f"repos/{REPOSITORY}/releases/tags/{tag}", "--include"],
                       runner, check=False)
    statuses = re.findall(r"^HTTP/\S+\s+([0-9]{3})\b", response.stdout, re.MULTILINE)
    if response.returncode == 0:
        raise ReleaseError(f"GitHub release {tag} already exists, including drafts")
    # Authentication/rate-limit/network failures must never be mistaken for absence.
    if not statuses or statuses[-1] != "404":
        raise ReleaseError("Could not confirm the GitHub release is absent (expected HTTP 404)")
    # The by-tag endpoint documents published releases. Enumerate authenticated release
    # pages as well so a draft without a pushed tag cannot be overlooked.
    listing = command(root, ["gh", "api", f"repos/{REPOSITORY}/releases", "--paginate", "--slurp"], runner)
    pages = json.loads(listing.stdout)
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise ReleaseError("Cannot read the complete GitHub release listing")
    if any(release.get("tag_name") == tag for page in pages for release in page):
        raise ReleaseError(f"GitHub release {tag} already exists, including drafts")


def asset_metadata(paths):
    expected = {}
    for path in paths:
        if not path.is_file() or path.is_symlink():
            raise ReleaseError(f"Missing regular release asset: {path.name}")
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        expected[path.name] = (path.stat().st_size, f"sha256:{digest}")
    return expected


def verify_uploaded_release(release, tag, expected, *, draft):
    if release.get("tagName") != tag or release.get("isDraft") is not draft or release.get("isPrerelease") is not False:
        raise ReleaseError("GitHub release identity/status differs from the intended stable release")
    assets = release.get("assets", [])
    if len(assets) != len(expected) or {asset.get("name") for asset in assets} != set(expected):
        raise ReleaseError("GitHub release assets do not match the three prepared files")
    for asset in assets:
        size, digest = expected[asset["name"]]
        if asset.get("state") != "uploaded" or asset.get("size") != size or asset.get("digest") != digest:
            raise ReleaseError(f"GitHub asset verification failed for {asset['name']}; draft is not published")


def view_release(root, tag, runner):
    result = command(root, ["gh", "release", "view", tag, "--repo", REPOSITORY, "--json",
                            "tagName,isDraft,isPrerelease,url,assets"], runner)
    return json.loads(result.stdout)


def publish(root, app, notes_file, out=None, tools_dir=None, runner=subprocess.run):
    root, app, notes_file = Path(root).resolve(), Path(app).resolve(), Path(notes_file).resolve()
    if not notes_file.is_file() or not notes_file.read_text(encoding="utf-8").strip():
        raise ReleaseError("Supply a nonempty release-notes file")
    version, build = read_identity(root, app)
    provenance.verify_receipt(root, app)
    tag = f"v{version}"
    out = Path(out).resolve() if out is not None else root / "build/releases" / tag
    if out.exists():
        raise ReleaseError("The release output directory already exists; no archives are overwritten")
    head = assert_clean_main(root, runner)
    assert_unused_release(root, tag, runner)
    packaging = [sys.executable, "-I", "-B", str(root / "scripts/package-update.py"),
                 "--app", str(app), "--out", str(out), "--notes-file", str(notes_file)]
    if tools_dir is not None:
        packaging.extend(["--tools-dir", str(Path(tools_dir).resolve())])
    command(root, packaging, runner)
    paths = [out / f"TalkTalk-{version}-macOS-arm64.zip", out / "SHA256SUMS.txt", out / "appcast.xml"]
    expected = asset_metadata(paths)
    # Recheck after signing: no source/network mutation has happened yet.
    if assert_clean_main(root, runner) != head:
        raise ReleaseError("Source HEAD changed while preparing the release")
    title = f"TalkTalk {version} (build {build})"
    command(root, ["git", "tag", "-a", tag, "-m", title, head], runner)
    command(root, ["git", "push", REMOTE, f"refs/tags/{tag}"], runner)
    command(root, ["gh", "release", "create", tag, "--repo", REPOSITORY, "--draft", "--verify-tag",
                   "--title", title, "--notes-file", str(notes_file)], runner)
    command(root, ["gh", "release", "upload", tag, *map(str, paths), "--repo", REPOSITORY], runner)
    verify_uploaded_release(view_release(root, tag, runner), tag, expected, draft=True)
    assert_remote_main(root, head, runner)
    command(root, ["gh", "release", "edit", tag, "--repo", REPOSITORY, "--draft=false", "--latest"], runner)
    final = view_release(root, tag, runner)
    verify_uploaded_release(final, tag, expected, draft=False)
    expected_url = f"https://github.com/{REPOSITORY}/releases/tag/{tag}"
    if final.get("url") != expected_url:
        raise ReleaseError("Published release returned an unexpected URL")
    return expected_url


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--notes-file", required=True, type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--tools-dir", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        url = publish(root, args.app or root / "build/TalkTalk.app", args.notes_file, args.out, args.tools_dir)
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError, ReleaseError) as error:
        print(f"publish-release: {error}", file=sys.stderr)
        print("If a tag or draft was already created, it is retained for inspection; no existing release was replaced.", file=sys.stderr)
        return 1
    print(url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
