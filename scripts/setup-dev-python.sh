#!/bin/bash
# setup-dev-python.sh [--check]: repository-owned Python and locked development dependencies.
# The interpreter stays in .build/dev-python and .venv refers only to that persistent path.
# Default setup downloads the pinned CPython/dependencies; --check is read-only and offline.
# No application runtime, model files, Keychain items or audio devices are touched.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
# shellcheck source=lib/versions.sh
. "$here/lib/versions.sh"
root="$(cd "$here/.." && pwd)"
dev_python="$root/.build/dev-python"
dev_venv="$root/.venv"
dev_bin="$dev_venv/bin/python3"
dev_cache="$root/.build/dev-python-cache"
dev_lock="$root/engine/requirements-engine.lock"
dev_build_lock="$root/engine/requirements-build.lock"

python_stamp() { printf 'python=%s release=%s sha256=%s recipe=%s\n' "$TT_PY_VERSION" "$TT_PY_RELEASE" "$TT_PY_SHA256" "$TT_ENGINE_RECIPE"; }
venv_stamp() { printf 'python=%s lock=%s build=%s recipe=%s dev=1\n' "$TT_PY_SHA256" "$TT_LOCK_SHA256" "$TT_BUILD_LOCK_SHA256" "$TT_ENGINE_RECIPE"; }

check_locks() {
  [ "$(tt_sha256 "$dev_lock")" = "$TT_LOCK_SHA256" ] || tt_die "requirements-engine.lock does not match versions.sh"
  [ "$(tt_sha256 "$dev_build_lock")" = "$TT_BUILD_LOCK_SHA256" ] || tt_die "requirements-build.lock does not match versions.sh"
}

python_ready() {
  [ -f "$dev_python/.talktalk-dev-python" ] && [ -x "$dev_python/bin/python3" ] \
    && [ "$(/bin/cat "$dev_python/.talktalk-dev-python")" = "$(python_stamp)" ]
}

check_environment() {
  python_ready && [ -x "$dev_bin" ] && [ -f "$dev_venv/.talktalk-dev-venv" ] \
    && [ "$(/bin/cat "$dev_venv/.talktalk-dev-venv")" = "$(venv_stamp)" ] || return 1
  # Metadata only: checking the environment must not import MLX or initialize Metal.
  "$dev_bin" -I -B - "$dev_python" "$dev_venv" "$TT_PY_VERSION" "$dev_lock" "$dev_build_lock" <<'PY'
import importlib.metadata as metadata
import importlib.util
import json
from pathlib import Path
import re
import sys

base, venv = (Path(p).resolve() for p in sys.argv[1:3])
expected = sys.argv[3]
if ".".join(map(str, sys.version_info[:3])) != expected:
    raise SystemExit(f"project Python must be {expected}")
if Path(sys.prefix).resolve() != venv or Path(sys.base_prefix).resolve() != base:
    raise SystemExit(".venv must use the repository's .build/dev-python interpreter")
for filename in sys.argv[4:]:
    for line in Path(filename).read_text(encoding="utf-8").splitlines():
        pinned = re.match(r"^([A-Za-z0-9_.-]+)==([^\s;\\]+)", line)
        direct = re.match(r"^([A-Za-z0-9_.-]+) @ (\S+)", line)
        try:
            if pinned:
                name, version = pinned.groups()
                if metadata.version(name) != version:
                    raise SystemExit(f"project dependency differs from lock: {name}=={version}")
            elif direct:
                name, url = direct.groups()
                source = json.loads(metadata.distribution(name).read_text("direct_url.json") or "{}")
                if source.get("url") != url:
                    raise SystemExit(f"project dependency differs from pinned source: {name}")
        except metadata.PackageNotFoundError as error:
            raise SystemExit(f"missing project dependency: {error.name}") from None
if importlib.util.find_spec("sounddevice") is not None:
    raise SystemExit("sounddevice must remain excluded from the project environment")
PY
}

case "${1:-}" in
  --check)
    [ $# -eq 1 ] || tt_die "usage: setup-dev-python.sh [--check]"
    check_locks
    check_environment || tt_die "project Python environment is missing or stale; run: $here/setup-dev-python.sh"
    exit 0 ;;
  '')
    [ $# -eq 0 ] || tt_die "usage: setup-dev-python.sh [--check]"
    /bin/mkdir -p "$root/.build"
    exec /usr/bin/lockf -k "$root/.build/.dev-python-setup.lock" "$here/setup-dev-python.sh" --setup-lock-held ;;
  --setup-lock-held) [ $# -eq 1 ] || tt_die "usage: setup-dev-python.sh [--check]" ;;
  *) tt_die "usage: setup-dev-python.sh [--check]" ;;
esac

[ "$(/usr/bin/uname -s)" = Darwin ] && [ "$(/usr/bin/uname -m)" = arm64 ] \
  || tt_die "the pinned development runtime requires Apple Silicon macOS"
check_locks
for path in "$dev_python" "$dev_venv" "$dev_cache"; do tt_assert_safe_dir "$path"; done

stage=""
trap '[ -z "$stage" ] || /bin/rm -rf "$stage"' EXIT
if ! python_ready || [ ! -f "$dev_python/.talktalk-manifest" ] \
    || ! tt_manifest_check "$dev_python" "$dev_python/.talktalk-manifest"; then
  [ ! -e "$dev_python" ] || [ -f "$dev_python/.talktalk-dev-owned" ] \
    || tt_die "$dev_python already exists but was not created by this setup script; move it aside first"
  /bin/mkdir -p "$dev_cache"
  archive="$dev_cache/$TT_PY_ASSET"
  tt_download "$TT_PY_URL" "$archive" "$TT_PY_SIZE" "$TT_PY_SHA256" "development CPython $TT_PY_VERSION"
  stage="$(/usr/bin/mktemp -d "$root/.build/.dev-python-stage.XXXXXX")"
  /usr/bin/tar -xzf "$archive" -C "$stage"
  [ -x "$stage/python/bin/python3" ] || tt_die "unexpected CPython archive layout"
  tt_manifest_build "$stage/python" > "$stage/manifest"
  /bin/mv "$stage/manifest" "$stage/python/.talktalk-manifest"
  python_stamp > "$stage/python/.talktalk-dev-python"
  : > "$stage/python/.talktalk-dev-owned"
  if [ -e "$dev_python" ]; then /bin/rm -rf "$dev_python"; fi
  /bin/mv "$stage/python" "$dev_python"
  /bin/rm -rf "$stage"; stage=""
fi

if check_environment >/dev/null 2>&1; then
  tt_log "project Python $TT_PY_VERSION and locked dependencies are ready"
  exit 0
fi
[ ! -e "$dev_venv" ] || [ -f "$dev_venv/.talktalk-dev-owned" ] \
  || tt_die "$dev_venv already exists but was not created by this setup script; move it aside first"
if [ -e "$dev_venv" ]; then /bin/rm -rf "$dev_venv"; fi
/bin/mkdir -p "$dev_venv"
: > "$dev_venv/.talktalk-dev-owned"
"$dev_python/bin/python3" -I -B -m venv "$dev_venv"
export PIP_CACHE_DIR="$dev_cache/pip" PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1
"$dev_bin" -I -B -m pip install --require-hashes --no-deps --only-binary :all: -r "$dev_build_lock"
"$dev_bin" -I -B -m pip install --require-hashes --no-deps --no-build-isolation \
  --only-binary :all: --no-binary mlx-audio -r "$dev_lock"
"$dev_bin" -I -B -c 'import mlx.core, mlx_audio, transformers, numpy; print("development imports ok")'
venv_stamp > "$dev_venv/.talktalk-dev-venv"
check_environment || tt_die "project environment verification failed; rerun $here/setup-dev-python.sh"
tt_log "project Python $TT_PY_VERSION ready: $dev_bin"
