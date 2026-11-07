#!/bin/bash
# install-engine.sh: install, verify or remove the talktalk engine runtime and models
# (ARCHITECTURE.md §7.3; derived from readread install-hq.sh's discipline).
#
#   install-engine.sh [--profile max|standard|compact24|compact16] [--json-progress]   install / update / repair
#   install-engine.sh --check [--json-progress]                                        verify only, exit 0/1
#   install-engine.sh --add-model <key> | --remove-model <key> [--json-progress]
#   install-engine.sh --uninstall [--json-progress]
#   install-engine.sh --no-smoke ...    M0 only: skip the smoke run; install.json is then NOT written
#
# Layout: $TALKTALK_ENGINE_HOME (default ~/Library/Application Support/TalkTalk/engine)
#   python/  venv/  models/<repo-name>@<rev12>/ (+ .talktalk-verified)  warmup/  install.json  .lock
# Network: github.com (CPython, mlx-audio tarball), pypi.org + files.pythonhosted.org, huggingface.co.
# Never reads ~/.readread or .../ReadRead; never touches the Keychain or OpenAI.
set -euo pipefail
umask 077

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
# shellcheck source=lib/versions.sh
. "$here/lib/versions.sh"
# shellcheck source=lib/models.sh
. "$here/lib/models.sh"

op="install"; profile=""; model_arg=""; smoke=1
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) profile="${2:-}"; shift 2 ;;
    --check) op="check"; shift ;;
    --add-model) op="add"; model_arg="${2:-}"; shift 2 ;;
    --remove-model) op="remove"; model_arg="${2:-}"; shift 2 ;;
    --uninstall) op="uninstall"; shift ;;
    --json-progress) TT_JSON_PROGRESS=1; shift ;;
    --no-smoke) smoke=0; shift ;;
    -h|--help) /usr/bin/sed -n '2,16p' "$0" >&2; exit 0 ;;
    *) tt_die "unknown argument: $1" ;;
  esac
done
export TT_JSON_PROGRESS

case "$here" in
  *.app/Contents/*) [ -n "${TALKTALK_BUILD_CACHE:-}" ] || tt_die "running inside an app bundle requires TALKTALK_BUILD_CACHE" ;;
esac

TT_HOME="${TALKTALK_HOME:-$HOME/Library/Application Support/TalkTalk}"
ENGINE_HOME="${TALKTALK_ENGINE_HOME:-$TT_HOME/engine}"
BUILD_CACHE="${TALKTALK_BUILD_CACHE:-$HOME/Library/Caches/TalkTalk/engine-build}"
ENGINE_SRC="${TALKTALK_ENGINE_SRC_DIR:-$(cd "$here/.." && pwd)/engine}"
# Test hook (InstallerTests): base URLs can point at file:// fixtures. Production uses the defaults.
HF_BASE="${TALKTALK_TEST_HF_BASE:-https://huggingface.co}"
PY_URL="${TALKTALK_TEST_PY_URL:-$TT_PY_URL}"
CURL_PROTO_OK=1
if [ -n "${TALKTALK_TEST_HF_BASE:-}${TALKTALK_TEST_PY_URL:-}" ]; then CURL_PROTO_OK=0; fi

PY_DIR="$ENGINE_HOME/python"; VENV_DIR="$ENGINE_HOME/venv"; MODELS_DIR="$ENGINE_HOME/models"
INSTALL_JSON="$ENGINE_HOME/install.json"; LOCK_LINK="$ENGINE_HOME/.lock"

for p in "$ENGINE_HOME" "$BUILD_CACHE"; do tt_assert_safe_dir "$p"; done

# ---------------------------------------------------------------- helpers

profile_models() {
  case "$1" in
    max) printf '%s' "$TT_PROFILE_MAX" ;;
    standard) printf '%s' "$TT_PROFILE_STANDARD" ;;
    compact24) printf '%s' "$TT_PROFILE_COMPACT24" ;;
    compact16) printf '%s' "$TT_PROFILE_COMPACT16" ;;
    *) tt_die "unknown profile: $1" ;;
  esac
}

installed_field() {
  # installed_field <jq filter>   reads install.json (or .prev) if present
  local f="$INSTALL_JSON"
  [ -f "$f" ] || f="$INSTALL_JSON.prev"
  [ -f "$f" ] || return 0
  /usr/bin/jq -r "$1 // empty" "$f" 2>/dev/null || true
}

matching_profile() {
  # Classify active role IDs only. Downloading an extra model never selects it.
  local roles="$1" declared="$2" actual expected prof k role
  actual="$(printf '%s' "$roles" | /usr/bin/jq -cS 'map_values(.id)')"
  for prof in "$declared" standard max compact24 compact16; do
    case "$prof" in max|standard|compact24|compact16) ;; *) continue ;; esac
    expected="{}"
    for k in $(profile_models "$prof"); do
      role="$(tt_model_field "$k" ROLE)"
      expected="$(printf '%s' "$expected" | /usr/bin/jq -cS --arg role "$role" --arg id "$k" '. + {($role):$id}')"
    done
    if [ "$actual" = "$expected" ]; then printf '%s' "$prof"; return 0; fi
  done
  printf 'custom'
}

installed_profile() {
  [ -f "$INSTALL_JSON" ] || [ -f "$INSTALL_JSON.prev" ] || return 0
  local roles
  roles="$(installed_field .roles)"
  [ -n "$roles" ] || roles="{}"
  matching_profile "$roles" "$(installed_field .profile)"
}

acquire_lock() {
  /bin/mkdir -p "$ENGINE_HOME"
  /bin/chmod 700 "$TT_HOME" 2>/dev/null || true
  if /bin/ln -s "$$" "$LOCK_LINK" 2>/dev/null; then return 0; fi
  local other
  other="$(/usr/bin/readlink "$LOCK_LINK" || true)"
  case "$other" in ''|*[!0-9]*) other="" ;; esac
  if [ -n "$other" ] && /bin/kill -0 "$other" 2>/dev/null; then
    tt_die "another install-engine.sh is running (pid $other)"
  fi
  tt_warn "taking over stale lock (pid ${other:-?})"
  /bin/rm -f "$LOCK_LINK"
  /bin/ln -s "$$" "$LOCK_LINK" || tt_die "could not take the install lock"
}

release_lock() {
  if [ -L "$LOCK_LINK" ] && [ "$(/usr/bin/readlink "$LOCK_LINK")" = "$$" ]; then /bin/rm -f "$LOCK_LINK"; fi
}

on_signal() { tt_log "interrupted; re-run to resume"; tt_event error message "interrupted"; release_lock; exit 130; }
trap on_signal INT TERM HUP
trap release_lock EXIT

mark_prev() {
  # First change of this run: install.json -> install.json.prev (its presence means "unfinished").
  if [ -f "$INSTALL_JSON" ]; then /bin/mv -f "$INSTALL_JSON" "$INSTALL_JSON.prev"; fi
}

python_stamp() { printf '%s %s %s recipe=%s\n' "$TT_PY_VERSION" "$TT_PY_RELEASE" "$TT_PY_SHA256" "$TT_ENGINE_RECIPE"; }
venv_stamp() { printf 'lock=%s build=%s python=%s recipe=%s\n' "$TT_LOCK_SHA256" "$TT_BUILD_LOCK_SHA256" "$TT_PY_SHA256" "$TT_ENGINE_RECIPE"; }

python_ok() {
  [ -f "$PY_DIR/.talktalk-python" ] && [ "$(/bin/cat "$PY_DIR/.talktalk-python")" = "$(python_stamp)" ] || return 1
  [ -x "$PY_DIR/bin/python3" ] || return 1
  # manifest: "<sha256>  <relative path>" for every regular file except bytecode caches
  tt_manifest_check "$PY_DIR" "$PY_DIR/.talktalk-manifest" || return 1
  return 0
}

install_python() {
  if python_ok; then tt_log "python: ok"; return 0; fi
  tt_event step step "python" "done" 0 count 1
  local tarball="$BUILD_CACHE/$TT_PY_ASSET" stage
  /bin/mkdir -p "$BUILD_CACHE"
  if [ "$CURL_PROTO_OK" = "1" ]; then
    tt_download "$PY_URL" "$tarball" "$TT_PY_SIZE" "$TT_PY_SHA256" "python"
  else
    tt_download_test "$PY_URL" "$tarball" "$TT_PY_SIZE" "$TT_PY_SHA256" "python"
  fi
  stage="$ENGINE_HOME/.python.tmp-$$"
  /bin/rm -rf "$stage"; /bin/mkdir -p "$stage"
  /usr/bin/tar -xzf "$tarball" -C "$stage"
  [ -x "$stage/python/bin/python3" ] || tt_die "unexpected CPython archive layout"
  # Manifest is built outside the tree it describes, then moved in (it must not list itself).
  tt_manifest_build "$stage/python" > "$stage/manifest"
  /bin/mv "$stage/manifest" "$stage/python/.talktalk-manifest"
  python_stamp > "$stage/python/.talktalk-python"
  if [ -e "$PY_DIR" ]; then
    [ -f "$PY_DIR/.talktalk-python" ] || [ -f "$PY_DIR/.talktalk-owned" ] || tt_die "$PY_DIR exists but was not created by this installer"
    /bin/rm -rf "$PY_DIR"
  fi
  : > "$stage/python/.talktalk-owned"
  /bin/mv "$stage/python" "$PY_DIR"
  /bin/rm -rf "$stage"
  tt_event step step "python" "done" 1 count 1
  tt_log "python: installed $TT_PY_VERSION"
}

venv_ok() {
  [ -f "$VENV_DIR/.talktalk-venv" ] && [ "$(/bin/cat "$VENV_DIR/.talktalk-venv")" = "$(venv_stamp)" ] && [ -x "$VENV_DIR/bin/python3" ]
}

install_venv() {
  if venv_ok; then tt_log "venv: ok"; return 0; fi
  local lock="$ENGINE_SRC/requirements-engine.lock" blk="$ENGINE_SRC/requirements-build.lock"
  [ "$(tt_sha256 "$lock")" = "$TT_LOCK_SHA256" ] || tt_die "requirements-engine.lock does not match TT_LOCK_SHA256"
  [ "$(tt_sha256 "$blk")" = "$TT_BUILD_LOCK_SHA256" ] || tt_die "requirements-build.lock does not match TT_BUILD_LOCK_SHA256"
  tt_event step step "venv" "done" 0 count 3
  if [ -e "$VENV_DIR" ]; then
    [ -f "$VENV_DIR/.talktalk-owned" ] || tt_die "$VENV_DIR exists but was not created by this installer"
    /bin/rm -rf "$VENV_DIR"
  fi
  # Mark ownership before `venv` runs: an install interrupted inside it must stay resumable.
  /bin/mkdir -p "$VENV_DIR"
  : > "$VENV_DIR/.talktalk-owned"
  "$PY_DIR/bin/python3" -I -B -m venv "$VENV_DIR"
  local pipenv="PIP_CACHE_DIR=$BUILD_CACHE/pip PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 PYTHONNOUSERSITE=1"
  tt_event step step "venv" "done" 1 count 3
  # shellcheck disable=SC2086  # pipenv is a deliberate list of VAR=value words for env(1)
  /usr/bin/env $pipenv "$VENV_DIR/bin/python3" -I -B -m pip install --quiet --require-hashes --no-deps --only-binary :all: -r "$blk" >&2 \
    || tt_die "pip failed on requirements-build.lock"
  tt_event step step "venv" "done" 2 count 3
  # mlx-audio is a commit tarball (sdist); everything else must be a wheel.
  # shellcheck disable=SC2086
  /usr/bin/env $pipenv "$VENV_DIR/bin/python3" -I -B -m pip install --quiet --require-hashes --no-deps --no-build-isolation \
      --only-binary :all: --no-binary mlx-audio -r "$lock" >&2 \
    || tt_die "pip failed on requirements-engine.lock"
  "$VENV_DIR/bin/python3" -I -B -c 'import mlx.core, mlx_audio, transformers, numpy; print("venv imports ok")' >&2 \
    || tt_die "venv import check failed"
  venv_stamp > "$VENV_DIR/.talktalk-venv"
  tt_event step step "venv" "done" 3 count 3
  tt_log "venv: installed from requirements-engine.lock"
}

write_install_json() {
  # --preserve-roles is for add/remove only: retain active revisions and existing
  # model entries instead of reinterpreting an old profile label with today's presets.
  local prof="$1"; shift
  local preserve=0 old_roles="{}" old_models="[]" entry
  if [ "${1:-}" = "--preserve-roles" ]; then
    preserve=1; shift
    old_roles="$(installed_field .roles)"; old_models="$(installed_field .models)"
  fi
  local tmp="$INSTALL_JSON.tmp-$$" roles="{}" models="[]" k role rev repo
  for k in "$@"; do
    role="$(tt_model_field "$k" ROLE)"; rev="$(tt_model_field "$k" REVISION)"; repo="$(tt_model_field "$k" REPO)"
    entry=""
    if [ "$preserve" = "1" ]; then
      entry="$(printf '%s' "$old_models" | /usr/bin/jq -c --arg id "$k" '[.[] | select(.id == $id)][0] // empty')"
    fi
    if [ -z "$entry" ]; then
      entry="$(/usr/bin/jq -nc --arg id "$k" --arg repo "$repo" --arg rev "$rev" --arg role "$role" \
        --arg dir "$(tt_model_dirname "$k")" '{id:$id, repo:$repo, rev:$rev, role:$role, dir:$dir}')"
    fi
    models="$(printf '%s' "$models" | /usr/bin/jq -c --argjson entry "$entry" '. + [$entry]')"
    if [ "$preserve" = "0" ] && tt_in_list "$k" "$(profile_models "$prof")"; then
      roles="$(printf '%s' "$roles" | /usr/bin/jq -c --arg role "$role" --arg id "$k" --arg rev "$rev" '. + {($role): {id:$id, rev:$rev}}')"
    fi
  done
  if [ "$preserve" = "1" ]; then
    roles="$(printf '%s' "$old_roles" | /usr/bin/jq -c --argjson models "$models" \
      'with_entries(select(.value.id as $id | any($models[]; .id == $id)))')"
    prof="$(matching_profile "$roles" "$prof")"
  fi
  /usr/bin/jq -n --arg profile "$prof" --argjson api "$TT_ENGINE_API" --arg lock "$TT_LOCK_SHA256" \
    --arg block "$TT_BUILD_LOCK_SHA256" --arg pyv "$TT_PY_VERSION" --arg pyr "$TT_PY_RELEASE" \
    --arg pysha "$TT_PY_SHA256" --arg mla "$TT_MLX_AUDIO_COMMIT" --argjson recipe "$TT_ENGINE_RECIPE" \
    --argjson roles "$roles" --argjson models "$models" --arg at "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{version:1, profile:$profile, engine_api:$api, runtime:"python-mlx", flavour:"main",
      lock_sha256:$lock, build_lock_sha256:$block, recipe:$recipe,
      python:{version:$pyv, release:$pyr, sha256:$pysha}, mlx_audio_commit:$mla,
      roles:$roles, models:$models, installed_at:$at}' > "$tmp"
  /bin/mv -f "$tmp" "$INSTALL_JSON"
  /bin/rm -f "$INSTALL_JSON.prev"
}

# Synthetic references made with `say` (§4.4, §7.3): only for generic warmup and smoke, never a
# real person's voice. The zh text is the enrollment script (§9.1), so the warmup reference has the
# same shape (~8-10 s) as a real one.
WARMUP_REF_TEXT="大家好，今天我先简单介绍一下项目的最新进展，然后说说下一步的计划。如果有问题，欢迎随时打断我。"
WARMUP_SAMPLE_TEXT="我们下周二上午十点开会，讨论第三季度的预算。"
make_warmup() {
  local w="$ENGINE_HOME/warmup"
  if [ -f "$w/ref-zh.wav" ] && [ -f "$w/ref-zh.txt" ] && [ -f "$w/sample-zh.wav" ] && [ -f "$w/sample-zh.txt" ]; then return 0; fi
  /bin/mkdir -p "$w"
  /usr/bin/say -v Tingting --file-format=WAVE --data-format=LEI16@24000 -o "$w/ref-zh.wav" "$WARMUP_REF_TEXT" \
    || tt_die "say -v Tingting failed (needs to run outside the sandbox; is the Tingting voice installed?)"
  printf '%s' "$WARMUP_REF_TEXT" > "$w/ref-zh.txt"
  /usr/bin/say -v Tingting --file-format=WAVE --data-format=LEI16@16000 -o "$w/sample-zh.wav" "$WARMUP_SAMPLE_TEXT" \
    || tt_die "say -v Tingting failed for the ASR sample"
  printf '%s' "$WARMUP_SAMPLE_TEXT" > "$w/sample-zh.txt"
  tt_log "warmup: synthetic references written"
}

run_smoke() {
  # run_smoke <profile>: §7.3 smoke run; install.json is written only if it passes.
  local prof="$1" py="$VENV_DIR/bin/python3"
  [ -f "$ENGINE_SRC/smoke_engine.py" ] || tt_die "smoke_engine.py not found in $ENGINE_SRC"
  tt_event step step "smoke" "done" 0 count 1
  "$py" -I -B "$ENGINE_SRC/smoke_engine.py" --engine-home "$ENGINE_HOME" --engine-src "$ENGINE_SRC" \
      --profile "$prof" --tts "$(role_key "$prof" tts)" --asr "$(role_key "$prof" asr)" >&2 \
    || tt_die "smoke run failed; install.json not written (re-run to retry)"
  tt_event step step "smoke" "done" 1 count 1
}

role_key() {
  # role_key <profile> <role> -> model key or empty
  local k
  for k in $(profile_models "$1"); do
    [ "$(tt_model_field "$k" ROLE)" = "$2" ] && { printf '%s' "$k"; return 0; }
  done
  return 0
}

need_bytes_for() {
  local total=0 k
  python_ok || total=$((total + TT_PY_SIZE * 5))
  venv_ok || total=$((total + 900000000))
  for k in "$@"; do total=$((total + $(model_missing_bytes "$k"))); done
  printf '%d' "$total"
}

check_space() {
  local need free
  need="$(need_bytes_for "$@")"; need=$((need + need / 10))
  free="$(tt_free_bytes "$ENGINE_HOME")"
  tt_log "disk: need $need bytes (incl. 10%), free $free"
  [ "$free" -ge "$need" ] || tt_die "not enough disk space: need $need bytes, have $free"
}

# ---------------------------------------------------------------- operations

do_install() {
  local prof="${profile:-$(installed_profile)}"
  [ "$prof" != "custom" ] || tt_die "active models form a custom combination; choose an explicit --profile to change it"
  # Preserve the former default's actual model combination; Max now opts into ASR 1.7B.
  prof="${prof:-standard}"
  local models k extra
  models="$(profile_models "$prof")"
  # keep models added earlier with --add-model
  extra="$(installed_field '.models[]?.id')"
  for k in $extra; do tt_in_list "$k" "$models" || { tt_in_list "$k" "$TT_MODELS" && models="$models $k"; }; done
  for k in $models; do check_model_key "$k"; done
  acquire_lock
  # shellcheck disable=SC2086  # word-split list of model keys
  check_space $models
  mark_prev
  install_python
  install_venv
  for k in $models; do install_model "$k"; done
  make_warmup
  if [ "$smoke" = "1" ]; then
    run_smoke "$prof"
    # shellcheck disable=SC2086
    write_install_json "$prof" $models
    tt_event "done" profile "$prof"
    tt_log "engine installed (profile $prof)"
  else
    tt_warn "--no-smoke: files are installed and verified, but install.json was not written"
    tt_event "done" profile "$prof" smoke "skipped"
  fi
}

do_add() {
  check_model_key "$model_arg"
  acquire_lock
  check_space "$model_arg"
  install_model "$model_arg"
  if [ -f "$INSTALL_JSON" ]; then
    local prof models
    prof="$(installed_profile)"; models="$(installed_field '.models[]?.id' | /usr/bin/tr '\n' ' ')"
    tt_in_list "$model_arg" "$models" || models="$models $model_arg"
    # shellcheck disable=SC2086
    write_install_json "$prof" --preserve-roles $models
  fi
  tt_event "done" model "$model_arg"
}

do_remove() {
  check_model_key "$model_arg"
  local prof d allow foreign models k keep=""
  prof="$(installed_profile)"
  if [ -n "$prof" ] && [ "$prof" != "custom" ] && tt_in_list "$model_arg" "$(profile_models "$prof")"; then
    tt_die "$model_arg is used by the current profile ($prof)"
  fi
  acquire_lock
  d="$(model_dir "$model_arg")"
  if [ -d "$d" ]; then
    tt_assert_safe_dir "$d"
    allow="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/tt-allow.XXXXXX")"
    model_allow_list "$model_arg" > "$allow"
    foreign="$(foreign_files "$d" "$allow")"; /bin/rm -f "$allow"
    [ -z "$foreign" ] || { printf '  %s\n' "$foreign" >&2; tt_die "refusing to delete $d: it contains files not created by this installer"; }
    /bin/rm -rf "$d"
  fi
  if [ -f "$INSTALL_JSON" ]; then
    models="$(installed_field '.models[]?.id')"
    for k in $models; do [ "$k" = "$model_arg" ] || keep="$keep $k"; done
    # shellcheck disable=SC2086
    write_install_json "$prof" --preserve-roles $keep
  fi
  tt_event "done" model "$model_arg" removed 1
}

do_check() {
  local prof k bad=0 models
  prof="$(installed_profile)"; prof="${prof:-${profile:-standard}}"
  [ -f "$INSTALL_JSON.prev" ] && { tt_log "unfinished: install.json.prev exists"; bad=1; }
  [ -f "$INSTALL_JSON" ] || { tt_log "install.json missing"; bad=1; }
  python_ok || { tt_log "python: not ok"; bad=1; }
  venv_ok || { tt_log "venv: not ok"; bad=1; }
  models="$(installed_field '.models[]?.id')"
  if [ -z "$models" ] && [ "$prof" != "custom" ]; then models="$(profile_models "$prof")"; fi
  for k in $models; do
    tt_event step step "check" model "$k"
    if model_full_verify "$k"; then tt_log "$k: ok"; else bad=1; fi
  done
  if [ "$bad" = "0" ]; then tt_event "done" ok 1; tt_log "check: ok"; exit 0; fi
  tt_event "done" ok 0; tt_log "check: problems found"; exit 1
}

do_uninstall() {
  acquire_lock
  local k d allow foreign
  for k in $TT_MODELS; do
    d="$(model_dir "$k")"
    [ -d "$d" ] || continue
    allow="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/tt-allow.XXXXXX")"
    model_allow_list "$k" > "$allow"
    foreign="$(foreign_files "$d" "$allow")"; /bin/rm -f "$allow"
    if [ -n "$foreign" ]; then tt_warn "keeping $d (foreign files: $(printf '%s' "$foreign" | /usr/bin/tr '\n' ' '))"; continue; fi
    /bin/rm -rf "$d"
  done
  [ -d "$MODELS_DIR" ] && /bin/rmdir "$MODELS_DIR" 2>/dev/null || true
  [ -d "$MODELS_DIR" ] && tt_warn "kept $MODELS_DIR: it still contains entries not created by this installer"
  for d in "$VENV_DIR" "$PY_DIR"; do
    [ -e "$d" ] || continue
    if [ -f "$d/.talktalk-owned" ]; then /bin/rm -rf "$d"; else tt_warn "keeping $d (not created by this installer)"; fi
  done
  if [ -d "$ENGINE_HOME/warmup" ]; then
    /bin/rm -f "$ENGINE_HOME/warmup/ref-zh.wav" "$ENGINE_HOME/warmup/ref-zh.txt" \
      "$ENGINE_HOME/warmup/sample-zh.wav" "$ENGINE_HOME/warmup/sample-zh.txt"
    /bin/rmdir "$ENGINE_HOME/warmup" 2>/dev/null || tt_warn "kept $ENGINE_HOME/warmup (foreign files)"
  fi
  /bin/rm -f "$INSTALL_JSON" "$INSTALL_JSON.prev"
  release_lock
  /bin/rmdir "$ENGINE_HOME" 2>/dev/null || tt_warn "kept $ENGINE_HOME (foreign files)"
  tt_event "done" uninstalled 1
}

case "$op" in
  install) do_install ;;
  check) do_check ;;
  add) do_add ;;
  remove) do_remove ;;
  uninstall) do_uninstall ;;
esac
