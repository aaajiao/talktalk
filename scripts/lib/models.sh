# shellcheck shell=bash
# Model install / verify helpers shared by scripts/install-engine.sh and tools/bench/fetch-bench-models.sh.
# Callers set: MODELS_DIR (absolute), HF_BASE, CURL_PROTO_OK (1 = https only), TT_MODELS (known keys),
# TT_LICENSE_ALLOW, TT_MODEL_DENY; and source common.sh plus the pin files first.

check_model_key() {
  tt_in_list "$1" "$TT_MODELS" || tt_die "unknown model key: $1 (known: $TT_MODELS)"
  local repo lic deny
  repo="$(tt_model_field "$1" REPO)"; lic="$(tt_model_field "$1" LICENSE)"
  tt_in_list "$lic" "$TT_LICENSE_ALLOW" || tt_die "$1: license $lic not allowed"
  for deny in $TT_MODEL_DENY; do
    case "$repo" in "$deny"*) tt_die "$1: $repo is on the deny list" ;; esac
  done
  [ -n "$(tt_model_files "$1")" ] || tt_die "$1: no pinned files"
}

foreign_files() {
  # foreign_files <dir> <allowed list file>: prints files under dir that are not allowed
  local dir="$1" allow="$2"
  ( cd "$dir" && /usr/bin/find . -type f -o -type l ) | /usr/bin/sed 's|^\./||' | LC_ALL=C /usr/bin/sort \
    | LC_ALL=C /usr/bin/comm -23 - "$allow"
}

model_allow_list() {
  # Allowed relative paths inside a model dir, sorted.
  { tt_model_files "$1" | /usr/bin/awk '{print $1}'
    tt_model_files "$1" | /usr/bin/awk '{print $1 ".part"}'
    printf '.talktalk-verified\n'; } | LC_ALL=C /usr/bin/sort
}

model_dir() { printf '%s/%s' "$MODELS_DIR" "$(tt_model_dirname "$1")"; }

model_file_url() {
  # A model may bundle a small auxiliary asset from a separately pinned repository.
  # FILE_SOURCES rows are: local-path repository revision remote-path.
  local key="$1" file="$2" path repo rev remote
  while read -r path repo rev remote; do
    [ "$path" = "$file" ] || continue
    printf '%s/%s/resolve/%s/%s' "$HF_BASE" "$repo" "$rev" "$remote"
    return 0
  done < <(tt_model_field "$key" FILE_SOURCES)
  printf '%s/%s/resolve/%s/%s' "$HF_BASE" "$(tt_model_field "$key" REPO)" \
    "$(tt_model_field "$key" REVISION)" "$file"
}

verify_model_source() {
  # An explicit local source is all-or-nothing: never quietly download missing files.
  local key="$1" source="$2" path bytes sha
  [ -d "$source" ] || tt_die "model source is not a directory: $source"
  while read -r path bytes sha; do
    [ -f "$source/$path" ] && [ "$(tt_fsize "$source/$path")" = "$bytes" ] \
      && [ "$(tt_sha256 "$source/$path")" = "$sha" ] \
      || tt_die "$key: local source $path does not match its pin"
  done < <(tt_model_files "$key")
}

model_missing_bytes() {
  local key="$1" d path bytes sha have total=0
  d="$(model_dir "$key")"
  while read -r path bytes sha; do
    have=0
    [ -f "$d/$path" ] && have="$bytes"
    [ -f "$d/$path" ] || { [ -f "$d/$path.part" ] && have="$(tt_fsize "$d/$path.part")"; }
    total=$((total + bytes - have))
    : "$sha"
  done < <(tt_model_files "$key")
  printf '%d' "$total"
}

model_quick_ok() {
  # verified stamp present and every pinned file has the pinned size (no hashing)
  local key="$1" d path bytes sha
  d="$(model_dir "$key")"
  [ -f "$d/.talktalk-verified" ] || return 1
  [ "$(/usr/bin/head -1 "$d/.talktalk-verified")" = "$(tt_model_field "$key" REVISION)" ] || return 1
  while read -r path bytes sha; do
    [ -f "$d/$path" ] && [ "$(tt_fsize "$d/$path")" = "$bytes" ] || return 1
    : "$sha"
  done < <(tt_model_files "$key")
  return 0
}

model_full_verify() {
  local key="$1" d path bytes sha bad=0
  d="$(model_dir "$key")"
  [ -f "$d/.talktalk-verified" ] || { tt_log "$key: not verified (no .talktalk-verified)"; return 1; }
  while read -r path bytes sha; do
    if [ ! -f "$d/$path" ] || [ "$(tt_fsize "$d/$path")" != "$bytes" ] || [ "$(tt_sha256 "$d/$path")" != "$sha" ]; then
      tt_log "$key: $path does not match its pin"; bad=1
    fi
  done < <(tt_model_files "$key")
  return "$bad"
}

install_model() {
  local key="$1" d repo rev path bytes sha n=0 count allow foreign url
  check_model_key "$key"
  d="$(model_dir "$key")"; repo="$(tt_model_field "$key" REPO)"; rev="$(tt_model_field "$key" REVISION)"
  count="$(tt_model_files "$key" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  if model_quick_ok "$key"; then
    tt_log "$key: already installed ($(tt_model_dirname "$key"))"
    tt_event step step "model" model "$key" "done" "$count" count "$count"
    return 0
  fi
  if [ -n "${MODEL_SOURCE:-}" ]; then verify_model_source "$key" "$MODEL_SOURCE"; fi
  /bin/mkdir -p "$d"
  allow="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/tt-allow.XXXXXX")"
  model_allow_list "$key" > "$allow"
  foreign="$(foreign_files "$d" "$allow")"
  /bin/rm -f "$allow"
  if [ -n "$foreign" ]; then
    tt_log "foreign files in $d (not created by this installer):"
    printf '  %s\n' "$foreign" >&2
    tt_die "refusing to install into $d; move those files away and re-run"
  fi
  /bin/rm -f "$d/.talktalk-verified"
  while read -r path bytes sha; do
    n=$((n + 1))
    tt_event step step "model" model "$key" "done" "$((n - 1))" count "$count"
    url="$(model_file_url "$key" "$path")"
    if [ -n "${MODEL_SOURCE:-}" ]; then
      /bin/mkdir -p "$(/usr/bin/dirname "$d/$path")"
      # APFS clones reuse the existing model's disk blocks; other volumes fall back to copy.
      /bin/cp -c "$MODEL_SOURCE/$path" "$d/$path.part" 2>/dev/null \
        || /bin/cp "$MODEL_SOURCE/$path" "$d/$path.part"
      [ "$(tt_fsize "$d/$path.part")" = "$bytes" ] && [ "$(tt_sha256 "$d/$path.part")" = "$sha" ] \
        || tt_die "$key: imported $path failed verification"
      /bin/mv -f "$d/$path.part" "$d/$path"
      tt_event download file "$key/$path" have "$bytes" total "$bytes" verified 1
    elif [ "$CURL_PROTO_OK" = "1" ]; then
      tt_download "$url" "$d/$path" "$bytes" "$sha" "$key/$path"
    else
      tt_download_test "$url" "$d/$path" "$bytes" "$sha" "$key/$path"
    fi
  done < <(tt_model_files "$key")
  { printf '%s\n' "$rev"; printf 'key=%s repo=%s verified_at=%s\n' "$key" "$repo" "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$d/.talktalk-verified"
  tt_event step step "model" model "$key" "done" "$count" count "$count"
  tt_log "$key: verified"
}

tt_download_test() {
  # Same contract as tt_download, for file:// fixtures in InstallerTests (no --proto restriction).
  # Emits the same download events, so the app's progress parsing is tested against them.
  local url="$1" dest="$2" bytes="$3" sha="$4" label="${5:-$(/usr/bin/basename "$2")}" have=0
  if [ -f "$dest" ] && [ "$(tt_fsize "$dest")" = "$bytes" ] && [ "$(tt_sha256 "$dest")" = "$sha" ]; then
    return 0
  fi
  /bin/mkdir -p "$(/usr/bin/dirname "$dest")"
  [ -f "$dest.part" ] && have="$(tt_fsize "$dest.part")"
  tt_event download file "$label" have "$have" total "$bytes"
  /usr/bin/curl -fsS -C - -o "$dest.part" "$url" || true
  [ -f "$dest.part" ] && [ "$(tt_fsize "$dest.part")" = "$bytes" ] && [ "$(tt_sha256 "$dest.part")" = "$sha" ] \
    || { /bin/rm -f "$dest.part"; tt_die "could not download and verify $label"; }
  /bin/mv -f "$dest.part" "$dest"
  tt_event download file "$label" have "$bytes" total "$bytes" verified 1
}
