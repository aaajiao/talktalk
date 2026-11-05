#!/bin/bash
# pin-model.sh <key> <repo> <revision> <role> [license]
# Prints a versions.sh block for one HF model repo pinned at a 40-char commit:
#   TT_M_<KEY>_REPO / _REVISION / _ROLE / _LICENSE / _FILES ("<path> <bytes> <sha256>" per line)
# LFS files take their sha256 from the HF API (lfs.sha256). Small non-LFS files are fetched,
# checked against the API size and git blob SHA-1, then hashed locally.
# Network: huggingface.co only. Writes nothing outside a private temp dir.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

[ $# -ge 4 ] || tt_die "usage: pin-model.sh <key> <repo> <40-char revision> <role> [license]"
key="$1"; repo="$2"; rev="$3"; role="$4"; license="${5:-}"
case "$rev" in *[!0-9a-f]*|'') tt_die "revision must be a 40-char hex commit" ;; esac
[ "${#rev}" -eq 40 ] || tt_die "revision must be a 40-char hex commit"

tmp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tt-pin.XXXXXX")"
trap '/bin/rm -rf "$tmp"' EXIT

api="https://huggingface.co/api/models/$repo/revision/$rev?blobs=true"
/usr/bin/curl -fsS --proto '=https' --retry 3 -o "$tmp/api.json" "$api" || tt_die "HF API request failed: $api"
got_rev="$(/usr/bin/jq -r '.sha' "$tmp/api.json")"
[ "$got_rev" = "$rev" ] || tt_die "HF API returned revision $got_rev, expected $rev"
if [ -z "$license" ]; then
  license="$(/usr/bin/jq -r '.cardData.license // empty' "$tmp/api.json")"
fi
case "$license" in
  apache-2.0|Apache-2.0) license="Apache-2.0" ;;
  mit|MIT) license="MIT" ;;
  *) tt_die "license '$license' is not on the allow list (Apache-2.0, MIT)" ;;
esac

files=""
while IFS=$'\t' read -r path size lfs_sha blob; do
  [ "$path" = ".gitattributes" ] && continue
  case "$path" in *' '*|/*|*..*) tt_die "unexpected file name in repo: $path" ;; esac
  if [ "$lfs_sha" != "-" ]; then
    sha="$lfs_sha"
  else
    out="$tmp/f/$path"
    /bin/mkdir -p "$(/usr/bin/dirname "$out")"
    /usr/bin/curl -fsSL --proto '=https' --retry 3 -o "$out" "https://huggingface.co/$repo/resolve/$rev/$path" \
      || tt_die "download failed: $path"
    [ "$(tt_fsize "$out")" = "$size" ] || tt_die "size mismatch for $path"
    gsha="$({ printf 'blob %d\0' "$size"; /bin/cat "$out"; } | /usr/bin/shasum -a 1 | /usr/bin/awk '{print $1}')"
    [ "$gsha" = "$blob" ] || tt_die "git blob sha1 mismatch for $path"
    sha="$(tt_sha256 "$out")"
  fi
  files="$files
$path $size $sha"
done < <(/usr/bin/jq -r '.siblings[] | [.rfilename, (.size|tostring), (.lfs.sha256 // "-"), .blobId] | @tsv' "$tmp/api.json" | LC_ALL=C /usr/bin/sort)

p="$(tt_model_prefix "$key")"
total="$(printf '%s\n' "$files" | /usr/bin/awk 'NF==3 {s+=$2} END {printf "%d", s}')"
printf '# %s  (%s bytes, pinned %s)\n' "$key" "$total" "$(/bin/date -u +%Y-%m-%d)"
printf '%sREPO="%s"\n' "$p" "$repo"
printf '%sREVISION="%s"\n' "$p" "$rev"
printf '%sROLE="%s"; %sLICENSE="%s"\n' "$p" "$role" "$p" "$license"
printf '%sFILES="%s\n"\n' "$p" "$files"
