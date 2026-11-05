# shellcheck shell=bash
# talktalk shared shell helpers (bash 3.2 compatible: no associative arrays, no ${x^^}).
# Sourced by install-engine.sh, pin-model.sh, gen-pins.sh and tools/bench/*.sh.
# Never echoes secrets; nothing here touches the Keychain.

TT_JSON_PROGRESS="${TT_JSON_PROGRESS:-0}"

# Human-readable messages always go to stderr; stdout is reserved for --json-progress events.
tt_log() { printf '%s\n' "$*" >&2; }
tt_warn() { printf 'warning: %s\n' "$*" >&2; }

tt_json_str() {
  # Minimal JSON string escaping for paths, keys and messages we generate ourselves.
  printf '%s' "$1" | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | /usr/bin/tr -d '\n\r'
}

tt_event() {
  # tt_event <event> [key value]...   values are emitted as JSON strings unless they are plain integers
  [ "$TT_JSON_PROGRESS" = "1" ] || return 0
  local ev="$1"; shift
  local out
  out="{\"event\":\"$(tt_json_str "$ev")\""
  while [ $# -ge 2 ]; do
    case "$2" in
      ''|*[!0-9]*) out="$out,\"$(tt_json_str "$1")\":\"$(tt_json_str "$2")\"" ;;
      *) out="$out,\"$(tt_json_str "$1")\":$2" ;;
    esac
    shift 2
  done
  printf '%s}\n' "$out"
}

tt_die() {
  tt_log "error: $*"
  tt_event error message "$*"
  exit 1
}

tt_sha256() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
tt_fsize() { /usr/bin/stat -f %z "$1"; }

# Model keys look like "tts-qwen3-1.7b-base-8bit"; their pin variables are
# TT_M_TTS_QWEN3_1_7B_BASE_8BIT_<FIELD>.
tt_model_prefix() {
  printf 'TT_M_%s_' "$(printf '%s' "$1" | LC_ALL=C /usr/bin/tr '[:lower:]' '[:upper:]' | LC_ALL=C /usr/bin/tr -c 'A-Z0-9\n' '_')"
}

tt_model_field() {
  # tt_model_field <key> <FIELD>  -> value or empty
  local var
  var="$(tt_model_prefix "$1")$2"
  eval "printf '%s' \"\${$var:-}\""
}

tt_model_dirname() {
  # <repo-name>@<rev12>
  local repo rev
  repo="$(tt_model_field "$1" REPO)"
  rev="$(tt_model_field "$1" REVISION)"
  [ -n "$repo" ] && [ -n "$rev" ] || return 1
  printf '%s@%s' "${repo##*/}" "$(printf '%s' "$rev" | /usr/bin/cut -c1-12)"
}

tt_model_files() {
  # Prints "<path> <bytes> <sha256>" lines for a model key (blank lines dropped).
  tt_model_field "$1" FILES | /usr/bin/awk 'NF==3'
}

tt_model_bytes() {
  tt_model_files "$1" | /usr/bin/awk '{s+=$2} END {printf "%d", s}'
}

tt_in_list() {
  # tt_in_list <word> <space separated list>
  local w="$1" x
  for x in $2; do [ "$x" = "$w" ] && return 0; done
  return 1
}

tt_free_bytes() {
  # Free bytes on the filesystem holding $1 (its nearest existing ancestor).
  local d="$1"
  while [ ! -d "$d" ]; do d="$(/usr/bin/dirname "$d")"; done
  /bin/df -k "$d" | /usr/bin/awk 'NR==2 {printf "%d", $4 * 1024}'
}

tt_assert_safe_dir() {
  # Refuse relative, shallow, symlinked or HOME-ancestor paths before deleting anything.
  local p="$1"
  case "$p" in /*) ;; *) tt_die "refusing relative path: $p" ;; esac
  case "$p" in *"/../"*|*"/./"*|*/..|*/.) tt_die "refusing non-canonical path: $p" ;; esac
  [ -L "$p" ] && tt_die "refusing symlink: $p"
  local depth
  depth="$(printf '%s' "$p" | /usr/bin/tr -cd '/' | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
  [ "$depth" -ge 4 ] || tt_die "refusing shallow path: $p"
  case "$HOME/" in "$p"/*|"$p/") tt_die "refusing HOME or its ancestor: $p" ;; esac
  return 0
}

# tt_download <url> <dest> <bytes> <sha256> [label]
# Resumes from <dest>.part, retries 5 times, verifies size and sha256; a bad .part is
# deleted and downloaded once more from scratch. Moves into place only when verified.
tt_download() {
  local url="$1" dest="$2" bytes="$3" sha="$4" label="${5:-$(/usr/bin/basename "$2")}"
  local part="$dest.part" attempt=0 fresh_retry=0 have
  if [ -f "$dest" ] && [ "$(tt_fsize "$dest")" = "$bytes" ] && [ "$(tt_sha256 "$dest")" = "$sha" ]; then
    return 0
  fi
  /bin/mkdir -p "$(/usr/bin/dirname "$dest")"
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    have=0
    [ -f "$part" ] && have="$(tt_fsize "$part")"
    if [ "$have" -gt "$bytes" ]; then
      tt_warn "$label: .part larger than pinned size; discarding"
      /bin/rm -f "$part"; have=0
    fi
    if [ "$have" -lt "$bytes" ]; then
      tt_event download file "$label" have "$have" total "$bytes"
      tt_log "download $label ($have/$bytes bytes)"
      # -C - resumes from the .part; curl itself retries transient failures 5 times.
      /usr/bin/curl -fL --proto '=https' --retry 5 --retry-delay 2 --retry-all-errors \
        --connect-timeout 30 -sS -C - -o "$part" "$url" \
        || tt_warn "curl failed for $label (attempt $attempt)"
      have=0
      [ -f "$part" ] && have="$(tt_fsize "$part")"
    fi
    if [ "$have" -lt "$bytes" ]; then
      continue   # incomplete: keep the .part and resume on the next attempt
    fi
    if [ "$have" = "$bytes" ] && [ "$(tt_sha256 "$part")" = "$sha" ]; then
      /bin/mv -f "$part" "$dest"
      tt_event download file "$label" have "$bytes" total "$bytes" verified 1
      return 0
    fi
    /bin/rm -f "$part"
    if [ "$fresh_retry" = "1" ]; then break; fi
    tt_warn "sha256 or size mismatch for $label; downloading once more from scratch"
    fresh_retry=1; attempt=$((attempt - 1))
  done
  tt_die "could not download and verify $label"
}

# CPython tree manifest (§7.3). Bytecode caches (__pycache__/, *.pyc) are excluded: the interpreter
# rewrites them whenever their source stamp differs (the stock tarball's encodings/*.pyc are
# rewritten on first run), so hashing them makes --check fail on a healthy install. Integrity is
# claimed for the sources and binaries; every installer and engine run uses -B so python/ itself is
# never written after install.
tt_manifest_filter() { /usr/bin/grep -v -E '(^|/)__pycache__/|\.pyc$' || true; }

tt_manifest_build() {
  # tt_manifest_build <dir>  -> "<sha256>  <relative path>" lines on stdout
  ( cd "$1" && /usr/bin/find . -type f | /usr/bin/sed 's|^\./||' | tt_manifest_filter | LC_ALL=C /usr/bin/sort \
      | /usr/bin/tr '\n' '\0' | /usr/bin/xargs -0 /usr/bin/shasum -a 256 )
}

tt_manifest_check() {
  # tt_manifest_check <dir> <manifest>: every listed non-bytecode file matches. Bytecode lines in a
  # manifest written by an older installer are ignored rather than failing an otherwise good tree.
  local m
  m="$(tt_manifest_filter < "$2")"
  [ -n "$m" ] || return 1
  ( cd "$1" && printf '%s\n' "$m" | /usr/bin/shasum -a 256 -s -c - )
}
