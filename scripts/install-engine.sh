#!/bin/bash
# install-engine.sh: install, verify or remove the talktalk engine runtime and models
# (ARCHITECTURE.md, "引擎、翻译与播放"; derived from readread install-hq.sh's discipline).
#
#   install-engine.sh [--profile max|standard|compact24|compact16] [--json-progress]   install / update / repair
#   install-engine.sh --recognition-only [--json-progress]             prepare Qwen ASR, preserve other roles
#   install-engine.sh --check [--json-progress]                                        verify only, exit 0/1
#   install-engine.sh --add-model <key> | --remove-model <key> [--json-progress]
#   install-engine.sh --select-tts <key> [--model-source <verified-local-directory>]
#   install-engine.sh --remove-model <key> --allow-active-model   caller must stop the engine first
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

op="install"; profile=""; model_arg=""; smoke=1; allow_active_model=0; recognition_only=0; MODEL_SOURCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) profile="${2:-}"; shift 2 ;;
    --recognition-only) recognition_only=1; shift ;;
    --check) op="check"; shift ;;
    --add-model) op="add"; model_arg="${2:-}"; shift 2 ;;
    --select-tts) op="select-tts"; model_arg="${2:-}"; shift 2 ;;
    --model-source) MODEL_SOURCE="${2:-}"; [ -n "$MODEL_SOURCE" ] || tt_die "--model-source needs a directory"; shift 2 ;;
    --remove-model) op="remove"; model_arg="${2:-}"; shift 2 ;;
    --allow-active-model) allow_active_model=1; shift ;;
    --uninstall) op="uninstall"; shift ;;
    --json-progress) TT_JSON_PROGRESS=1; shift ;;
    --no-smoke) smoke=0; shift ;;
    -h|--help) /usr/bin/sed -n '2,16p' "$0" >&2; exit 0 ;;
    *) tt_die "unknown argument: $1" ;;
  esac
done
if [ "$recognition_only" = "1" ]; then
  [ "$op" = "install" ] && [ -z "$profile" ] || tt_die "--recognition-only cannot be combined with another operation or --profile"
  [ "$smoke" = "1" ] || tt_die "--recognition-only requires a successful ASR smoke check"
fi
[ "$allow_active_model" = "0" ] || [ "$op" = "remove" ] || tt_die "--allow-active-model requires --remove-model"
[ -z "$MODEL_SOURCE" ] || [ "$op" = "add" ] || [ "$op" = "select-tts" ] || tt_die "--model-source requires --add-model or --select-tts"
if [ "$op" = "select-tts" ]; then
  [ -z "$profile" ] || tt_die "--select-tts cannot change the resource profile"
  [ "$smoke" = "1" ] || tt_die "--select-tts requires a successful smoke check"
fi
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

make_asr_sample() {
  local w="$ENGINE_HOME/warmup"
  if [ -f "$w/sample-zh.wav" ] && [ -f "$w/sample-zh.txt" ]; then return 0; fi
  /bin/mkdir -p "$w"
  /usr/bin/say -v Tingting --file-format=WAVE --data-format=LEI16@16000 -o "$w/sample-zh.wav" "$WARMUP_SAMPLE_TEXT" \
    || tt_die "say -v Tingting failed for the ASR sample"
  printf '%s' "$WARMUP_SAMPLE_TEXT" > "$w/sample-zh.txt"
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

run_tts_selection_smoke() {
  local tts="$1" asr="$2"
  [ -f "$ENGINE_SRC/smoke_engine.py" ] || tt_die "smoke_engine.py not found in $ENGINE_SRC"
  tt_event step step "smoke" "done" 0 count 1
  "$VENV_DIR/bin/python3" -I -B "$ENGINE_SRC/smoke_engine.py" --engine-home "$ENGINE_HOME" \
      --engine-src "$ENGINE_SRC" --profile custom --tts "$tts" --asr "$asr" >&2 \
    || tt_die "TTS smoke check failed; previous model selection retained"
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

compatible_runtime() {
  # Reuse a verified shared runtime, including a supported older Python build. The
  # real model smoke below validates its imports and inference before completion.
  local pyv pyr pysha lock stamp
  [ "$(installed_field .engine_api)" = "$TT_ENGINE_API" ] || return 1
  [ "$(installed_field .recipe)" = "$TT_ENGINE_RECIPE" ] || return 1
  lock="$(installed_field .lock_sha256)"
  tt_in_list "$lock" "${TT_LOCK_COMPAT:-$TT_LOCK_SHA256}" || return 1
  pyv="$(installed_field .python.version)"; pyr="$(installed_field .python.release)"; pysha="$(installed_field .python.sha256)"
  [ -n "$pyv" ] && [ -n "$pyr" ] && [ -n "$pysha" ] || return 1
  [ -x "$PY_DIR/bin/python3" ] && [ -x "$VENV_DIR/bin/python3" ] || return 1
  [ -f "$PY_DIR/.talktalk-python" ] && [ -f "$VENV_DIR/.talktalk-venv" ] || return 1
  [ "$(/bin/cat "$PY_DIR/.talktalk-python")" = "$pyv $pyr $pysha recipe=$TT_ENGINE_RECIPE" ] || return 1
  stamp="$(/bin/cat "$VENV_DIR/.talktalk-venv")"
  [ "$stamp" = "lock=$lock build=$(installed_field .build_lock_sha256) python=$pysha recipe=$TT_ENGINE_RECIPE" ] || return 1
  tt_manifest_check "$PY_DIR" "$PY_DIR/.talktalk-manifest"
}

prepare_additive_model() {
  # ADDED_ROLES/MODELS retain every unrelated role and downloaded model entry.
  local role="$1" key="$2" rev entry dir stamp reuse=0
  check_model_key "$key"
  [ "$(tt_model_field "$key" ROLE)" = "$role" ] || tt_die "$key: invalid $role model"
  rev="$(printf '%s' "$ADDED_ROLES" | /usr/bin/jq -r --arg role "$role" '.[$role].rev // empty')"
  entry="$(printf '%s' "$ADDED_MODELS" | /usr/bin/jq -c --arg key "$key" --arg rev "$rev" '[.[] | select(.id == $key and .rev == $rev)][0] // empty')"
  if [ -n "$entry" ]; then
    dir="$(printf '%s' "$entry" | /usr/bin/jq -r .dir)"
    case "$dir" in ''|*/*|.|..) tt_die "$key: invalid model directory" ;; esac
    stamp="$MODELS_DIR/$dir/.talktalk-verified"
    if [ -f "$stamp" ] && [ "$(/usr/bin/head -1 "$stamp")" = "$rev" ]; then
      if [ "$rev" = "$(tt_model_field "$key" REVISION)" ]; then
        if [ "$dir" = "$(tt_model_dirname "$key")" ] && model_full_verify "$key"; then reuse=1; fi
      elif tt_in_list "$rev" "$(tt_model_field "$key" COMPAT_REVISIONS)"; then
        reuse=1 # The selected compatible revision is also checked by real inference.
      fi
    fi
  fi
  if [ "$reuse" = "0" ]; then
    # Re-download a same-size corrupted current model instead of trusting its quick stamp.
    /bin/rm -f "$(model_dir "$key")/.talktalk-verified"
    install_model "$key"
    model_full_verify "$key" || tt_die "$key: model verification failed"
    rev="$(tt_model_field "$key" REVISION)"
    entry="$(/usr/bin/jq -nc --arg id "$key" --arg repo "$(tt_model_field "$key" REPO)" --arg rev "$rev" \
      --arg role "$role" --arg dir "$(tt_model_dirname "$key")" '{id:$id,repo:$repo,rev:$rev,role:$role,dir:$dir}')"
    ADDED_MODELS="$(printf '%s' "$ADDED_MODELS" | /usr/bin/jq -c --arg key "$key" --argjson entry "$entry" '[.[] | select(.id != $key)] + [$entry]')"
  fi
  ADDED_ROLES="$(printf '%s' "$ADDED_ROLES" | /usr/bin/jq -c --arg role "$role" --arg id "$key" --arg rev "$rev" '.[$role]={id:$id,rev:$rev}')"
}

validate_preserved_roles() {
  local role key rev dir stamp
  while IFS='|' read -r role key rev; do
    [ -n "$role" ] || continue
    check_model_key "$key"
    [ "$(tt_model_field "$key" ROLE)" = "$role" ] || tt_die "$key: invalid installed role; repair speech resources first"
    { [ "$rev" = "$(tt_model_field "$key" REVISION)" ] \
      || tt_in_list "$rev" "$(tt_model_field "$key" COMPAT_REVISIONS)"; } \
      || tt_die "$key: existing revision is incompatible; repair speech resources first"
    dir="$(printf '%s' "$ADDED_MODELS" | /usr/bin/jq -r --arg key "$key" --arg rev "$rev" '.[] | select(.id == $key and .rev == $rev) | .dir')"
    case "$dir" in ''|*/*|.|..) tt_die "$key: invalid model directory; repair speech resources first" ;; esac
    stamp="$MODELS_DIR/$dir/.talktalk-verified"
    [ -f "$stamp" ] && [ "$(/usr/bin/head -1 "$stamp")" = "$rev" ] \
      || tt_die "$key: existing model is unverified; repair speech resources first"
    if [ "$rev" = "$(tt_model_field "$key" REVISION)" ]; then
      if [ "$dir" != "$(tt_model_dirname "$key")" ] || ! model_full_verify "$key"; then
        tt_die "$key: existing model is incomplete; repair speech resources first"
      fi
    fi
  done < <(printf '%s' "$ADDED_ROLES" | /usr/bin/jq -r 'to_entries[] | select(.key != "asr") | [.key,.value.id,.value.rev] | join("|")')
}

do_additive_install() {
  local scope="$1" previous='{}' source runtime_reused=0 asr tts prof tmp role key rev dir
  local smoke_args=()
  acquire_lock
  source="$INSTALL_JSON"; [ -f "$source" ] || source="$INSTALL_JSON.prev"
  if [ -f "$source" ]; then
    /usr/bin/jq -e '.version == 1 and (.roles | type == "object") and (.models | type == "array")' "$source" >/dev/null \
      || tt_die "repair the installation record before preparing recognition"
    previous="$(/bin/cat "$source")"
  fi
  ADDED_ROLES="$(printf '%s' "$previous" | /usr/bin/jq -c '.roles // {}')"
  ADDED_MODELS="$(printf '%s' "$previous" | /usr/bin/jq -c '.models // []')"
  asr="$(printf '%s' "$ADDED_ROLES" | /usr/bin/jq -r '.asr.id // empty')"
  tts="$(printf '%s' "$ADDED_ROLES" | /usr/bin/jq -r '.tts.id // empty')"
  if [ "$scope" = "recognition" ]; then
    asr="${asr:-$(role_key standard asr)}"
    # A damaged preserved TTS role would make the complete install record unusable
    # in the app. Fail before mutation rather than reporting a false completion.
    validate_preserved_roles
  else
    tts="${tts:-$(role_key standard tts)}"
  fi
  [ -z "$asr" ] || check_model_key "$asr"
  [ -z "$tts" ] || [ "$scope" = "recognition" ] || check_model_key "$tts"
  if compatible_runtime; then
    runtime_reused=1
    tt_log "python and venv: compatible shared runtime retained"
  fi
  # Recognition never requires space for TTS weights or repairs the TTS role.
  if [ "$scope" = "recognition" ]; then check_space "$asr"; else check_space "$tts" ${asr:+"$asr"}; fi
  mark_prev
  if [ "$runtime_reused" = "0" ]; then install_python; install_venv; fi
  [ -z "$asr" ] || prepare_additive_model asr "$asr"
  if [ "$scope" != "recognition" ]; then prepare_additive_model tts "$tts"; make_warmup; else make_asr_sample; fi
  prof="$(matching_profile "$ADDED_ROLES" "$(printf '%s' "$previous" | /usr/bin/jq -r '.profile // empty')")"
  for role in asr tts; do
    [ "$scope" != "recognition" ] || [ "$role" != "tts" ] || continue
    key="$(printf '%s' "$ADDED_ROLES" | /usr/bin/jq -r --arg role "$role" '.[$role].id // empty')"
    [ -n "$key" ] || continue
    rev="$(printf '%s' "$ADDED_ROLES" | /usr/bin/jq -r --arg role "$role" '.[$role].rev')"
    dir="$(printf '%s' "$ADDED_MODELS" | /usr/bin/jq -r --arg key "$key" --arg rev "$rev" '.[] | select(.id == $key and .rev == $rev) | .dir')"
    smoke_args+=("--$role" "$key" "--$role-model-dir" "$MODELS_DIR/$dir" "--$role-revision" "$rev")
  done
  [ -f "$ENGINE_SRC/smoke_engine.py" ] || tt_die "smoke_engine.py not found in $ENGINE_SRC"
  tt_event step step "smoke" "done" 0 count 1
  "$VENV_DIR/bin/python3" -I -B "$ENGINE_SRC/smoke_engine.py" --engine-home "$ENGINE_HOME" --engine-src "$ENGINE_SRC" \
    --profile "$prof" "${smoke_args[@]}" >&2 || tt_die "smoke run failed; install.json not written (re-run to retry)"
  tt_event step step "smoke" "done" 1 count 1
  # Keep compatible runtime metadata and unknown record fields; replace metadata only
  # when the shared runtime was installed/upgraded by this operation.
  if [ "$runtime_reused" = "0" ]; then
    previous="$(printf '%s' "$previous" | /usr/bin/jq -c --argjson api "$TT_ENGINE_API" --arg lock "$TT_LOCK_SHA256" \
      --arg block "$TT_BUILD_LOCK_SHA256" --arg pyv "$TT_PY_VERSION" --arg pyr "$TT_PY_RELEASE" --arg pysha "$TT_PY_SHA256" \
      --arg mla "$TT_MLX_AUDIO_COMMIT" --argjson recipe "$TT_ENGINE_RECIPE" \
      '. + {version:1,engine_api:$api,runtime:"python-mlx",flavour:"main",lock_sha256:$lock,build_lock_sha256:$block,
        recipe:$recipe,python:{version:$pyv,release:$pyr,sha256:$pysha},mlx_audio_commit:$mla}')"
  fi
  tmp="$INSTALL_JSON.tmp-$$"
  printf '%s' "$previous" | /usr/bin/jq --argjson roles "$ADDED_ROLES" --argjson models "$ADDED_MODELS" --arg profile "$prof" \
    --arg at "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" '.roles=$roles | .models=$models | .profile=$profile | .installed_at=$at' > "$tmp"
  /bin/mv -f "$tmp" "$INSTALL_JSON"
  /bin/rm -f "$INSTALL_JSON.prev"
  tt_event "done" profile "$prof"
  tt_log "engine installed ($scope resources; existing selections retained)"
}

do_install() {
  if [ "$recognition_only" = "1" ]; then do_additive_install recognition; return; fi
  # Maintenance Repair has no completed record from which to infer the failed
  # operation. An unfinished ASR-only install must stay ASR-only; adding speech
  # resources is a separate choice after recognition has finished successfully.
  if [ -z "$profile" ] && [ ! -f "$INSTALL_JSON" ] && [ -f "$INSTALL_JSON.prev" ] \
    && /usr/bin/jq -e '(.roles | keys) == ["asr"]' "$INSTALL_JSON.prev" >/dev/null; then
    [ "$smoke" = "1" ] || tt_die "recognition recovery requires a successful ASR smoke check"
    do_additive_install recognition; return
  fi
  local prof="${profile:-$(installed_profile)}"
  if [ "$prof" = "custom" ]; then
    [ "$(installed_field '.roles | length')" != "0" ] || tt_die "no active models; choose an explicit --profile to repair"
    [ "$smoke" = "1" ] || tt_die "custom resource completion requires a successful smoke check"
    do_additive_install speech; return
  fi
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

do_select_tts() {
  check_model_key "$model_arg"
  [ "$(tt_model_field "$model_arg" ROLE)" = "tts" ] || tt_die "--select-tts requires a TTS model"
  acquire_lock
  [ -f "$INSTALL_JSON" ] && [ ! -e "$INSTALL_JSON.prev" ] \
    || tt_die "finish the engine installation before selecting a TTS model"
  /usr/bin/jq -e '.version == 1 and (.roles | type == "object") and (.models | type == "array")' "$INSTALL_JSON" >/dev/null \
    || tt_die "repair the installation record before selecting a TTS model"
  [ "$(installed_field .engine_api)" = "$TT_ENGINE_API" ] \
    && tt_in_list "$(installed_field .lock_sha256)" "${TT_LOCK_COMPAT:-$TT_LOCK_SHA256}" \
    && [ -x "$VENV_DIR/bin/python3" ] && [ -f "$VENV_DIR/.talktalk-venv" ] \
    && [ -f "$PY_DIR/.talktalk-python" ] \
    || tt_die "repair the compatible engine runtime before selecting a TTS model"
  local roles asr role id rev dir stamp selected_rev selected_repo entry prof tmp
  roles="$(installed_field .roles)"
  # Other active roles must keep their exact model and revision; do not apply a named preset.
  while IFS='|' read -r role id rev; do
    [ -n "$role" ] || continue
    check_model_key "$id"
    [ "$(tt_model_field "$id" ROLE)" = "$role" ] || tt_die "invalid installed role: $role"
    { [ "$rev" = "$(tt_model_field "$id" REVISION)" ] \
      || tt_in_list "$rev" "$(tt_model_field "$id" COMPAT_REVISIONS)"; } \
      || tt_die "$id: installed revision is incompatible"
    dir="$(installed_field ".models[]? | select(.id == \"$id\" and .rev == \"$rev\") | .dir")"
    case "$dir" in ''|*/*|.|..) tt_die "$id: invalid model directory" ;; esac
    stamp="$MODELS_DIR/$dir/.talktalk-verified"
    [ -f "$stamp" ] && [ "$(/usr/bin/head -1 "$stamp")" = "$rev" ] \
      || tt_die "$id: existing active model is not verified"
  done < <(printf '%s' "$roles" | /usr/bin/jq -r 'to_entries[] | select(.key != "tts") | [.key,.value.id,.value.rev] | join("|")')
  check_space "$model_arg"
  install_model "$model_arg"
  model_full_verify "$model_arg" || tt_die "$model_arg: model verification failed"
  asr="$(printf '%s' "$roles" | /usr/bin/jq -r '.asr.id // empty')"
  make_warmup
  run_tts_selection_smoke "$model_arg" "$asr"
  selected_rev="$(tt_model_field "$model_arg" REVISION)"
  selected_repo="$(tt_model_field "$model_arg" REPO)"
  entry="$(/usr/bin/jq -nc --arg id "$model_arg" --arg repo "$selected_repo" --arg rev "$selected_rev" \
    --arg dir "$(tt_model_dirname "$model_arg")" '{id:$id,repo:$repo,rev:$rev,role:"tts",dir:$dir}')"
  roles="$(printf '%s' "$roles" | /usr/bin/jq -c --arg id "$model_arg" --arg rev "$selected_rev" '.tts={id:$id,rev:$rev}')"
  prof="$(matching_profile "$roles" "$(installed_field .profile)")"
  tmp="$INSTALL_JSON.tmp-$$"
  # The old record remains valid throughout download, smoke, failure and cancellation.
  # Preserve its runtime metadata and every other model entry. Commit is one atomic rename.
  /usr/bin/jq --argjson roles "$roles" --arg profile "$prof" --argjson entry "$entry" \
    --arg at "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.roles=$roles | .profile=$profile | .models=([.models[] | select(.id != $entry.id)]+[$entry]) | .installed_at=$at' \
    "$INSTALL_JSON" > "$tmp"
  /bin/mv -f "$tmp" "$INSTALL_JSON"
  tt_event "done" profile "$prof" model "$model_arg"
  tt_log "active TTS: $model_arg; other roles and downloaded models retained"
}

do_remove() {
  check_model_key "$model_arg"
  acquire_lock
  local prof d allow foreign models active k keep=""
  prof="$(installed_profile)"
  active="$(installed_field '.roles[]?.id' | /usr/bin/tr '\n' ' ')"
  if [ "$allow_active_model" = "0" ] && tt_in_list "$model_arg" "$active"; then
    tt_die "$model_arg is active; stop the engine and use --allow-active-model to remove it"
  fi
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
  select-tts) do_select_tts ;;
  remove) do_remove ;;
  uninstall) do_uninstall ;;
esac
