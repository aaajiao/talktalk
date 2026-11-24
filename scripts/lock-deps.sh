#!/bin/bash
# lock-deps.sh [--upgrade]: regenerate engine/requirements-engine.lock and engine/requirements-build.lock.
#
# uv resolves every dependency with hashes. mlx-audio is pinned to a GitHub commit tarball
# (TT_MLX_AUDIO_COMMIT in versions.sh, the same URL as engine/requirements-engine.in), which uv
# refuses to unpack (a file name in examples/ contains ':'). Resolution therefore goes through the
# PyPI release named by the tarball's mlx_audio/version.py, whose pyproject dependencies must be
# identical (checked below); the tarball line is added afterwards with its sha256. pip installs that
# line with --require-hashes like any other.
# By default the current locks seed the resolution, so packages that still satisfy the inputs keep
# their pins and only what the inputs require changes. --upgrade resolves every package afresh.
# sounddevice is left out on purpose: the engine stubs it (no PortAudio, no Core Audio client).
# Network: pypi.org, files.pythonhosted.org, github.com.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
# shellcheck source=lib/versions.sh
. "$here/lib/versions.sh"
root="$(cd "$here/.." && pwd)"
eng="$root/engine"
upgrade=0
case "${1:-}" in
  "") ;;
  --upgrade) upgrade=1 ;;
  *) echo "usage: scripts/lock-deps.sh [--upgrade]" >&2; exit 2 ;;
esac
[[ "$TT_PY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || tt_die "TT_PY_VERSION must be a major.minor.patch release"
python_target="${TT_PY_VERSION%.*}"

MLX_AUDIO_COMMIT="$TT_MLX_AUDIO_COMMIT"
[[ "$MLX_AUDIO_COMMIT" =~ ^[0-9a-f]{40}$ ]] || tt_die "TT_MLX_AUDIO_COMMIT must be a full commit sha"
MLX_AUDIO_URL="https://github.com/Neywa-Labs/mlx-audio/archive/$MLX_AUDIO_COMMIT.tar.gz"
if [ "$(/usr/bin/grep -c '^mlx-audio @ ' "$eng/requirements-engine.in")" != 1 ] \
  || ! /usr/bin/grep -qxF "mlx-audio @ $MLX_AUDIO_URL" "$eng/requirements-engine.in"; then
  tt_die "engine/requirements-engine.in must pin mlx-audio @ $MLX_AUDIO_URL (TT_MLX_AUDIO_COMMIT)"
fi

command -v uv >/dev/null || tt_die "uv not found (brew install uv)"
export MACOSX_DEPLOYMENT_TARGET=26.0   # mlx 0.32.4 ships macosx_14/15/26 wheels only
export UV_CACHE_DIR="${UV_CACHE_DIR:-${TMPDIR:-/tmp}/tt-uv-cache}"
tmp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tt-lock.XXXXXX")"
trap '/bin/rm -rf "$tmp"' EXIT

# 1. Fetch the tarball and hash it; take the proxy release from its version.py and confirm the two
#    dependency lists match (comment lines inside pyproject's list are not dependencies).
/usr/bin/curl -fsSL --proto '=https' --retry 3 -o "$tmp/mlx-audio.tar.gz" "$MLX_AUDIO_URL"
url_sha="$(tt_sha256 "$tmp/mlx-audio.tar.gz")"
src="mlx-audio-$MLX_AUDIO_COMMIT"
/usr/bin/tar -xzf "$tmp/mlx-audio.tar.gz" -C "$tmp" "$src/pyproject.toml" "$src/mlx_audio/version.py"
proxy_version="$(/usr/bin/sed -n 's/^__version__ = "\([0-9][0-9.]*\)"$/\1/p' "$tmp/$src/mlx_audio/version.py")"
[ -n "$proxy_version" ] && [ "$(printf '%s\n' "$proxy_version" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ] \
  || tt_die "cannot read __version__ from mlx_audio/version.py at $MLX_AUDIO_COMMIT"
MLX_AUDIO_PROXY="mlx-audio==$proxy_version"
/usr/bin/awk '/^dependencies = \[/{f=1;next} f&&/^\]/{f=0} f&&!/^[[:space:]]*#/' "$tmp/$src/pyproject.toml" \
  | /usr/bin/tr -d ' ",' | /usr/bin/sed '/^$/d' | LC_ALL=C /usr/bin/sort > "$tmp/deps.commit"
[ -s "$tmp/deps.commit" ] || tt_die "no [project] dependencies found in pyproject.toml at $MLX_AUDIO_COMMIT"
/usr/bin/curl -fsSL --proto '=https' --retry 3 "https://pypi.org/pypi/mlx-audio/$proxy_version/json" \
  | /usr/bin/jq -r '.info.requires_dist[] | select(test("extra ==") | not)' \
  | /usr/bin/tr -d ' ' | LC_ALL=C /usr/bin/sort > "$tmp/deps.proxy"
if ! /usr/bin/diff -u "$tmp/deps.commit" "$tmp/deps.proxy" >&2; then
  tt_die "mlx-audio dependencies at $MLX_AUDIO_COMMIT differ from PyPI $MLX_AUDIO_PROXY"
fi

# 2. Seed uv with the current pins (unless --upgrade): the existing lock bodies, without the
#    generated header and without the mlx-audio tarball entry appended below.
#    A lock that does not exist yet is resolved afresh.
if [ "$upgrade" = 0 ]; then
  if [ -f "$eng/requirements-engine.lock" ]; then
    /usr/bin/sed -e '1,3d' -e '/^# mlx-audio$/,$d' "$eng/requirements-engine.lock" > "$tmp/requirements-engine.lock"
  else
    tt_log "requirements-engine.lock missing: resolving it afresh"
  fi
  if [ -f "$eng/requirements-build.lock" ]; then
    /usr/bin/sed '1d' "$eng/requirements-build.lock" > "$tmp/build.lock"
  else
    tt_log "requirements-build.lock missing: resolving it afresh"
  fi
fi

# 3. Resolve with the proxy, then swap in the pinned tarball. Both runs use relative input paths
#    so the "# via -r" annotations, and with them the lock hashes, do not depend on $tmp.
/usr/bin/sed "s|^mlx-audio @ .*|$MLX_AUDIO_PROXY|" "$eng/requirements-engine.in" > "$tmp/requirements-engine.in"
( cd "$tmp" && uv pip compile requirements-engine.in -o requirements-engine.lock --generate-hashes --no-header --quiet \
    --python-version "$python_target" --python-platform aarch64-apple-darwin \
    --no-emit-package sounddevice --no-emit-package mlx-audio )
{
  printf '# Generated by scripts/lock-deps.sh from engine/requirements-engine.in. Do not edit.\n'
  printf '# Install: pip install --require-hashes --no-deps --no-build-isolation -r requirements-engine.lock\n'
  printf '# (after requirements-build.lock). sounddevice is intentionally absent (engine stub).\n'
  /bin/cat "$tmp/requirements-engine.lock"
  printf 'mlx-audio @ %s \\\n    --hash=sha256:%s\n    # via -r requirements-engine.in (commit tarball; resolved as %s)\n' \
    "$MLX_AUDIO_URL" "$url_sha" "$MLX_AUDIO_PROXY"
} > "$eng/requirements-engine.lock"

( cd "$root" && uv pip compile engine/requirements-build.in -o "$tmp/build.lock" --generate-hashes --no-header --quiet \
    --python-version "$python_target" --python-platform aarch64-apple-darwin )
{
  printf '# Generated by scripts/lock-deps.sh from engine/requirements-build.in. Do not edit.\n'
  /bin/cat "$tmp/build.lock"
} > "$eng/requirements-build.lock"

tt_log "requirements-engine.lock sha256 $(tt_sha256 "$eng/requirements-engine.lock")"
tt_log "requirements-build.lock  sha256 $(tt_sha256 "$eng/requirements-build.lock")"
tt_log "mlx-audio tarball sha256 $url_sha ($MLX_AUDIO_PROXY)"
tt_log "update TT_LOCK_SHA256 / TT_BUILD_LOCK_SHA256 (and TT_LOCK_COMPAT) in scripts/lib/versions.sh"
