#!/bin/bash
# shellcheck disable=SC2015  # ok/no always return 0, so "A && ok || no" is a safe if-then-else
# End-to-end tests of install-engine.sh against file:// fixtures (no network, no real CPython,
# no MLX): a copy of the installer with a fake versions.sh, a fake CPython tarball whose python3
# is a shell script, two tiny fake models and fake lock files. Covers install / --check /
# re-run / repair / --uninstall, --json-progress output, install.json written last (.prev on a
# failed smoke), the run lock, the in-bundle TALKTALK_BUILD_CACHE rule, foreign-file refusal,
# --remove-model of a profile model, and SIGTERM. Runs inside the Claude Code sandbox.
# Run: scripts/tests/test-installer.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck source=../lib/common.sh
. "$root/scripts/lib/common.sh"

work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tt-installer-test.XXXXXX")"
trap '/bin/rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Invert one byte in place. A fixed replacement byte equals the random fixture byte 1 time in 256,
# which left the file unchanged and made the corruption check fail by chance.
flip_byte() { # file offset
  _b="$(/usr/bin/od -An -tu1 -j"$2" -N1 "$1" | /usr/bin/tr -d ' ')"
  printf '%b' "\\0$(printf '%03o' $((_b ^ 255)))" | /bin/dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null
}

# --- the installer copy -------------------------------------------------------------------
tree="$work/tree"
/bin/mkdir -p "$tree/scripts/lib" "$tree/engine"
/bin/cp "$root/scripts/install-engine.sh" "$tree/scripts/"
/bin/cp "$root/scripts/lib/common.sh" "$root/scripts/lib/models.sh" "$tree/scripts/lib/"
printf 'fake-engine-lock==1\n' > "$tree/engine/requirements-engine.lock"
printf 'fake-build-lock==1\n' > "$tree/engine/requirements-build.lock"
printf '# fake smoke (the fake python3 decides the result)\n' > "$tree/engine/smoke_engine.py"

# --- fake CPython: python/bin/python3 is a script that fakes venv, pip, -c and the smoke run ----
/bin/mkdir -p "$work/pysrc/python/bin" "$work/pysrc/python/lib/python3.12"
printf 'print("fake stdlib")\n' > "$work/pysrc/python/lib/python3.12/os.py"
/bin/cat > "$work/pysrc/python/bin/python3" <<EOF
#!/bin/bash
while [ "\${1:-}" = "-I" ] || [ "\${1:-}" = "-B" ]; do shift; done
case "\${1:-}" in
  -m)
    case "\${2:-}" in
      venv) [ -f "$work/venv_sleep" ] && /bin/sleep 2
            /bin/mkdir -p "\$3/bin"; /bin/cp "\$0" "\$3/bin/python3"; /bin/chmod +x "\$3/bin/python3"; exit 0 ;;
      pip) exit 0 ;;
    esac ;;
  -c) exit 0 ;;
  *smoke_engine.py) printf '%s\\n' "\$@" > "$work/smoke_args"
                   : > "$work/smoke_active"
                   [ -f "$work/smoke_sleep" ] && /bin/sleep 2
                   exit "\$(/bin/cat "$work/smoke_rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
EOF
/bin/chmod +x "$work/pysrc/python/bin/python3"
/usr/bin/tar -czf "$work/py.tar.gz" -C "$work/pysrc" python

# --- fake models on a file:// "Hugging Face" -------------------------------------------------
rev_t="1111111111111111111111111111111111111111"; rev_a="2222222222222222222222222222222222222222"
mk_model() {  # mk_model <repo> <rev> -> prints the FILES block
  local d="$work/hf/$1/resolve/$2"
  /bin/mkdir -p "$d/sub"
  printf '{"m":"%s"}\n' "$1" > "$d/config.json"
  /bin/dd if=/dev/urandom of="$d/sub/model.safetensors" bs=1024 count=64 2>/dev/null
  printf 'config.json %s %s\n' "$(tt_fsize "$d/config.json")" "$(tt_sha256 "$d/config.json")"
  printf 'sub/model.safetensors %s %s\n' "$(tt_fsize "$d/sub/model.safetensors")" "$(tt_sha256 "$d/sub/model.safetensors")"
}
files_t="$(mk_model acme/Fake-TTS "$rev_t")"; files_a="$(mk_model acme/Fake-ASR "$rev_a")"
rev_large="3333333333333333333333333333333333333333"
files_large="$(mk_model acme/Fake-ASR-Large "$rev_large")"
rev_m="4444444444444444444444444444444444444444"
files_m="$(mk_model acme/Fake-Ming "$rev_m")"
native="$work/hf/acme/Native-Speaker/resolve/5555555555555555555555555555555555555555/campplus.safetensors"
/bin/mkdir -p "$(/usr/bin/dirname "$native")"
printf 'native speaker encoder fixture' > "$native"
files_m="$files_m
speaker_encoder/campplus.safetensors $(tt_fsize "$native") $(tt_sha256 "$native")"

/bin/cat > "$tree/scripts/lib/versions.sh" <<EOF
# shellcheck shell=bash
# fake pins for test-installer.sh
TT_PY_VERSION="3.12.15"; TT_PY_RELEASE="20261013"
TT_PY_ASSET="cpython-fake.tar.gz"; TT_PY_URL="https://example.invalid/never-used"
TT_PY_SIZE=$(tt_fsize "$work/py.tar.gz"); TT_PY_SHA256="$(tt_sha256 "$work/py.tar.gz")"
TT_ENGINE_RECIPE=1; TT_ENGINE_API=2; TT_MLX_AUDIO_COMMIT="f65753b55f011f4cc8b1dbc7622ae8110b7b7fbb"
TT_LOCK_SHA256="$(tt_sha256 "$tree/engine/requirements-engine.lock")"
TT_BUILD_LOCK_SHA256="$(tt_sha256 "$tree/engine/requirements-build.lock")"
TT_LOCK_COMPAT="\$TT_LOCK_SHA256"; TT_RUNTIME_FLAVOURS="main"
TT_MODELS="fake-tts fake-ming fake-asr fake-asr-large"
TT_PROFILE_MAX="fake-tts fake-asr"; TT_PROFILE_STANDARD="fake-tts fake-asr"
TT_PROFILE_COMPACT24="fake-tts fake-asr"; TT_PROFILE_COMPACT16="fake-tts"
TT_LICENSE_ALLOW="Apache-2.0 MIT"; TT_MODEL_DENY="tencent/HY-MT"
TT_M_FAKE_TTS_REPO="acme/Fake-TTS"; TT_M_FAKE_TTS_REVISION="$rev_t"; TT_M_FAKE_TTS_ROLE="tts"; TT_M_FAKE_TTS_LICENSE="MIT"
TT_M_FAKE_TTS_FILES="
$files_t
"
TT_M_FAKE_MING_REPO="acme/Fake-Ming"; TT_M_FAKE_MING_REVISION="$rev_m"; TT_M_FAKE_MING_ROLE="tts"; TT_M_FAKE_MING_LICENSE="MIT"
TT_M_FAKE_MING_FILES="
$files_m
"
TT_M_FAKE_MING_FILE_SOURCES="
speaker_encoder/campplus.safetensors acme/Native-Speaker 5555555555555555555555555555555555555555 campplus.safetensors
"
TT_M_FAKE_ASR_REPO="acme/Fake-ASR"; TT_M_FAKE_ASR_REVISION="$rev_a"; TT_M_FAKE_ASR_ROLE="asr"; TT_M_FAKE_ASR_LICENSE="MIT"
TT_M_FAKE_ASR_FILES="
$files_a
"
TT_M_FAKE_ASR_LARGE_REPO="acme/Fake-ASR-Large"; TT_M_FAKE_ASR_LARGE_REVISION="$rev_large"; TT_M_FAKE_ASR_LARGE_ROLE="asr"; TT_M_FAKE_ASR_LARGE_LICENSE="MIT"
TT_M_FAKE_ASR_LARGE_FILES="
$files_large
"
EOF

home="$work/home"; eng="$home/engine"
/bin/mkdir -p "$eng/warmup"   # `say` does not run here: provide the synthetic references
for f in ref-zh.wav ref-zh.txt sample-zh.wav sample-zh.txt; do printf 'x' > "$eng/warmup/$f"; done

inst() {  # inst <args...>: run the installer copy; stdout -> $work/out, stderr -> $work/err
  /usr/bin/env TALKTALK_HOME="$home" TALKTALK_ENGINE_HOME="$eng" TALKTALK_BUILD_CACHE="$work/cache" \
    TALKTALK_ENGINE_SRC_DIR="$tree/engine" TALKTALK_TEST_HF_BASE="file://$work/hf" \
    TALKTALK_TEST_PY_URL="file://$work/py.tar.gz" /bin/bash "$tree/scripts/install-engine.sh" "$@" \
    > "$work/out" 2> "$work/err"
}
all_json() { [ ! -s "$work/out" ] || /usr/bin/jq -e -s 'length > 0' "$work/out" > /dev/null 2>&1; }
last_event() { /usr/bin/tail -1 "$work/out" | /usr/bin/jq -r .event; }

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ ! -s "$work/err" ] || /usr/bin/tail -5 "$work/err" | /usr/bin/sed 's/^/     /'; }

# 0. Video-only preparation installs ASR without TTS or a voice reference.
/bin/rm -f "$eng/warmup/ref-zh.wav" "$eng/warmup/ref-zh.txt"
inst --recognition-only --no-smoke && no "recognition cannot bypass smoke" || ok "recognition cannot bypass smoke"
inst --recognition-only --profile standard && no "recognition rejects a preset" || ok "recognition rejects a preset"
inst --recognition-only --check && no "recognition rejects other operations" || ok "recognition rejects other operations"
inst --recognition-only --json-progress && ok "fresh recognition install succeeds" || no "fresh recognition install"
[ "$(/usr/bin/jq -c '.roles | keys' "$eng/install.json")" = '["asr"]' ] \
  && [ "$(/usr/bin/jq -r .roles.asr.id "$eng/install.json")" = fake-asr ] \
  && [ "$(/usr/bin/jq -r '.models | length' "$eng/install.json")" = 1 ] \
  && [ ! -e "$eng/models/Fake-TTS@111111111111" ] && [ ! -e "$eng/warmup/ref-zh.wav" ] \
  && ok "recognition has only the default ASR and no TTS reference" || no "recognition resource scope"
/usr/bin/grep -q '^--asr$' "$work/smoke_args" && ! /usr/bin/grep -q '^--tts$' "$work/smoke_args" \
  && /usr/bin/grep -q '^--asr-revision$' "$work/smoke_args" \
  && ok "recognition smoke launches only the selected ASR revision" || no "recognition smoke scope"
inst --check && ok "recognition-only record passes check" || no "recognition check"
inst --recognition-only --json-progress && ! /usr/bin/grep -q '"event":"download"' "$work/out" \
  && ok "recognition retry reuses Python, dependencies and model" || no "recognition reuse"
echo 1 > "$work/smoke_rc"
inst --recognition-only && no "failed ASR smoke cannot complete" || ok "failed ASR smoke cannot complete"
[ ! -f "$eng/install.json" ] && [ -f "$eng/install.json.prev" ] \
  && ok "failed ASR smoke remains unfinished" || no "recognition failure status"
echo 0 > "$work/smoke_rc"
inst && [ ! -e "$eng/install.json.prev" ] \
  && [ "$(/usr/bin/jq -c '.roles | keys' "$eng/install.json")" = '["asr"]' ] \
  && [ ! -e "$eng/models/Fake-TTS@111111111111" ] && [ ! -e "$eng/warmup/ref-zh.wav" ] \
  && ! /usr/bin/grep -q '^--tts$' "$work/smoke_args" \
  && ok "bare Repair resumes unfinished ASR-only install without adding TTS" || no "recognition repair scope"
asr_before="$(/usr/bin/jq -cS .roles.asr "$eng/install.json")"
for f in ref-zh.wav ref-zh.txt; do printf 'x' > "$eng/warmup/$f"; done
inst && [ "$(/usr/bin/jq -cS .roles.asr "$eng/install.json")" = "$asr_before" ] \
  && [ "$(/usr/bin/jq -r .roles.tts.id "$eng/install.json")" = fake-tts ] \
  && ok "later speech setup adds TTS while retaining ASR" || no "speech upgrade from video"
inst --uninstall
/bin/mkdir -p "$eng/warmup"
for f in ref-zh.wav ref-zh.txt sample-zh.wav sample-zh.txt; do printf 'x' > "$eng/warmup/$f"; done

# 1. fresh install
inst --json-progress && ok "fresh install exits 0" || no "fresh install"
all_json && ok "--json-progress: stdout is JSON events only" || no "stdout JSON"
[ "$(last_event)" = "done" ] && ok "last event is done" || no "last event"
/usr/bin/grep -q '"event":"download"' "$work/out" && ok "download events emitted" || no "download events"
/usr/bin/grep -q 'engine installed (profile standard)' "$work/err" && ok "default retains standard model combination" || no "default profile"
[ "$(/usr/bin/jq -r '.roles.tts.id + " " + .roles.asr.rev' "$eng/install.json")" = "fake-tts $rev_a" ] \
  && ok "install.json records roles" || no "install.json roles"
[ ! -e "$eng/install.json.prev" ] && [ ! -e "$eng/.lock" ] && ok "no .prev, lock released" || no ".prev/lock"
[ -f "$eng/python/.talktalk-manifest" ] && [ -f "$eng/venv/.talktalk-venv" ] && [ -f "$eng/python/.talktalk-owned" ] \
  && ok "stamps and ownership marks written" || no "stamps"
[ "$(/usr/bin/stat -f %Lp "$eng/install.json")" = "600" ] && ok "install.json is 0600 (umask 077)" || no "perms"

# 2. --check and re-run
inst --check && /usr/bin/grep -q 'check: ok' "$work/err" && ok "--check passes" || no "--check"
inst --json-progress && /usr/bin/grep -q 'python: ok' "$work/err" && /usr/bin/grep -q 'venv: ok' "$work/err" \
  && ! /usr/bin/grep -q '"event":"download"' "$work/out" && ok "re-run downloads nothing" || no "re-run"

# 3. corruption -> --check fails -> install repairs
flip_byte "$eng/models/Fake-TTS@111111111111/sub/model.safetensors" 10
inst --check && no "corruption fails --check" || ok "corruption fails --check"
/bin/rm -f "$eng/models/Fake-TTS@111111111111/.talktalk-verified"
inst && inst --check && ok "install repairs, --check passes again" || no "repair"

# 4. failed smoke: install.json is not written, .prev marks the unfinished run
echo 1 > "$work/smoke_rc"
inst && no "failed smoke fails the install" || ok "failed smoke fails the install"
[ ! -e "$eng/install.json" ] && [ -f "$eng/install.json.prev" ] && ok "install.json not written; .prev kept" || no ".prev after failed smoke"
inst --check && no "--check fails while unfinished" || ok "--check fails while unfinished"
echo 0 > "$work/smoke_rc"
inst && [ -f "$eng/install.json" ] && [ ! -e "$eng/install.json.prev" ] && ok "re-run finishes and clears .prev" || no "finish after .prev"

# 5. run lock
/bin/sleep 30 & sleeper=$!
/bin/ln -s "$sleeper" "$eng/.lock"
inst && no "live lock refused" || ok "live lock refused"
/usr/bin/grep -q "another install-engine.sh is running (pid $sleeper)" "$work/err" && ok "lock holder named" || no "lock message"
/bin/kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true
/bin/rm -f "$eng/.lock"; /bin/ln -s 99999999 "$eng/.lock"
inst && /usr/bin/grep -q 'taking over stale lock' "$work/err" && ok "stale lock taken over" || no "stale lock"

# 6. inside an app bundle without TALKTALK_BUILD_CACHE
app="$work/TalkTalk.app/Contents/Resources/installer"; /bin/mkdir -p "$app"; /bin/cp -R "$tree/scripts" "$app/"
/usr/bin/env TALKTALK_HOME="$home" TALKTALK_ENGINE_HOME="$eng" /bin/bash "$app/scripts/install-engine.sh" --check \
  > "$work/out" 2> "$work/err" && no "bundle without build cache refused" || ok "bundle without build cache refused"
/usr/bin/grep -q 'requires TALKTALK_BUILD_CACHE' "$work/err" && ok "bundle rule message" || no "bundle message"

# 7. removing a model the profile uses is refused
inst --remove-model fake-asr && no "profile model removal refused" || ok "profile model removal refused"
[ -d "$eng/models/Fake-ASR@222222222222" ] && ok "profile model kept" || no "profile model kept"

# 7a. TTS-only selection preserves the ASR, runtime metadata, and the other TTS download.
inst --add-model fake-ming \
  && /usr/bin/cmp -s "$native" "$eng/models/Fake-Ming@444444444444/speaker_encoder/campplus.safetensors" \
  && ok "auxiliary speaker asset uses its separately pinned source" || no "auxiliary speaker source"
inst --remove-model fake-ming
source_m="$work/pre-downloaded-ming"
/bin/cp -R "$work/hf/acme/Fake-Ming/resolve/$rev_m" "$source_m"
/bin/mkdir -p "$source_m/speaker_encoder"
/bin/cp "$native" "$source_m/speaker_encoder/campplus.safetensors"
# The source may contain Hugging Face cache metadata: import only pinned files.
/bin/mkdir -p "$source_m/.cache"
printf 'keep me' > "$source_m/.cache/download-metadata"
/bin/mv "$work/hf/acme/Fake-Ming" "$work/fake-ming-remote-disabled"
/usr/bin/jq '.python.version="3.12.14" | .custom_metadata="must-survive"' "$eng/install.json" > "$work/record.json"
/bin/mv "$work/record.json" "$eng/install.json"
asr_before="$(/usr/bin/jq -cS .roles.asr "$eng/install.json")"
runtime_before="$(/usr/bin/jq -cS '{engine_api,runtime,flavour,lock_sha256,build_lock_sha256,recipe,python,mlx_audio_commit,custom_metadata}' "$eng/install.json")"
record_before="$(tt_sha256 "$eng/install.json")"
inst --select-tts fake-ming --model-source "$work/missing-source" \
  && no "missing local source refuses without network fallback" || ok "missing local source refuses without network fallback"
[ "$(tt_sha256 "$eng/install.json")" = "$record_before" ] && [ ! -e "$eng/install.json.prev" ] \
  && ok "failed import leaves the active record intact" || no "import rollback"
inst --select-tts fake-ming --model-source "$source_m" --json-progress \
  && [ "$(/usr/bin/jq -r .roles.tts.id "$eng/install.json")" = fake-ming ] \
  && [ "$(/usr/bin/jq -cS .roles.asr "$eng/install.json")" = "$asr_before" ] \
  && [ "$(/usr/bin/jq -r .profile "$eng/install.json")" = custom ] \
  && ok "local import selects only TTS while remote is unavailable" || no "local TTS selection"
/usr/bin/grep -q '^fake-ming$' "$work/smoke_args" && /usr/bin/grep -q '^fake-asr$' "$work/smoke_args" \
  && ok "TTS smoke uses selected TTS and the existing ASR" || no "TTS smoke role arguments"
[ "$(/usr/bin/jq -cS '{engine_api,runtime,flavour,lock_sha256,build_lock_sha256,recipe,python,mlx_audio_commit,custom_metadata}' "$eng/install.json")" = "$runtime_before" ] \
  && ok "TTS selection preserves runtime and unknown record metadata" || no "TTS runtime metadata"
[ -d "$eng/models/Fake-TTS@111111111111" ] && [ -f "$source_m/.cache/download-metadata" ] \
  && [ ! -e "$eng/models/Fake-Ming@444444444444/.cache" ] \
  && ok "TTS selection retains Qwen files and imports no foreign cache files" || no "selection preserved files"
inst --select-tts fake-tts --json-progress \
  && [ "$(/usr/bin/jq -r .roles.tts.id "$eng/install.json")" = fake-tts ] \
  && [ "$(/usr/bin/jq -cS .roles.asr "$eng/install.json")" = "$asr_before" ] \
  && ! /usr/bin/grep -q '"event":"download"' "$work/out" \
  && ok "switching back reuses installed TTS and keeps ASR" || no "switch back"
record_before="$(tt_sha256 "$eng/install.json")"
echo 1 > "$work/smoke_rc"
inst --select-tts fake-ming && no "TTS smoke failure refuses activation" || ok "TTS smoke failure refuses activation"
[ "$(tt_sha256 "$eng/install.json")" = "$record_before" ] && [ ! -e "$eng/install.json.prev" ] \
  && ok "failed TTS smoke retains the previous selection" || no "TTS smoke rollback"
echo 0 > "$work/smoke_rc"
/bin/rm -f "$work/smoke_active"
: > "$work/smoke_sleep"
inst --select-tts fake-ming --json-progress & selection_runner=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ ! -e "$work/smoke_active" ] || break
  /bin/sleep 0.1
done
selection_pid="$(/usr/bin/readlink "$eng/.lock" 2>/dev/null || true)"
[ -n "$selection_pid" ] && /bin/kill -TERM "$selection_pid"
selection_rc=0; wait "$selection_runner" || selection_rc=$?
[ "$selection_rc" = 130 ] && [ "$(tt_sha256 "$eng/install.json")" = "$record_before" ] \
  && [ ! -e "$eng/install.json.prev" ] && [ ! -e "$eng/.lock" ] \
  && ok "cancelled TTS selection retains the active record and releases the lock" || no "TTS selection cancellation"
/bin/rm -f "$work/smoke_sleep"
inst --select-tts fake-ming --no-smoke && no "TTS selection cannot bypass smoke" || ok "TTS selection cannot bypass smoke"
inst --select-tts fake-asr && no "TTS selector rejects ASR models" || ok "TTS selector rejects ASR models"
inst --select-tts fake-ming --profile max && no "TTS selector rejects profile changes" || ok "TTS selector rejects profile changes"
[ "$(tt_sha256 "$eng/install.json")" = "$record_before" ] \
  && ok "invalid TTS selection flags leave the record intact" || no "invalid TTS selection changed record"
/bin/mv "$work/fake-ming-remote-disabled" "$work/hf/acme/Fake-Ming"
inst --remove-model fake-ming

# 7b. A new app changes Max's composition; old labels must not select the new ASR.
set_record() {
  /usr/bin/jq "$1" "$eng/install.json" > "$work/record.json"
  /bin/mv "$work/record.json" "$eng/install.json"
}
printf '\nTT_PROFILE_MAX="fake-tts fake-asr-large"\n' >> "$tree/scripts/lib/versions.sh"
set_record '.profile = "max"'
inst && [ "$(/usr/bin/jq -r .profile "$eng/install.json")" = standard ] \
  && [ ! -d "$eng/models/Fake-ASR-Large@333333333333" ] \
  && ok "implicit repair of old Max keeps standard roles" || no "legacy Max repair"
set_record '.profile = "max"'
roles_before="$(/usr/bin/jq -cS .roles "$eng/install.json")"
inst --add-model fake-asr-large && [ "$(/usr/bin/jq -cS .roles "$eng/install.json")" = "$roles_before" ] \
  && [ "$(/usr/bin/jq -r .profile "$eng/install.json")" = standard ] \
  && ok "adding larger ASR does not activate it under old Max label" || no "legacy Max add"
inst --remove-model fake-asr && no "actual standard ASR removal refused" || ok "actual standard ASR removal refused"
inst --remove-model fake-asr-large && [ "$(/usr/bin/jq -cS .roles "$eng/install.json")" = "$roles_before" ] \
  && ok "unused larger ASR can be removed without changing roles" || no "unused ASR removal"

# Explicit active removal keeps the other role and never activates a spare download.
inst --add-model fake-asr-large
tts_before="$(/usr/bin/jq -cS .roles.tts "$eng/install.json")"
inst --remove-model fake-asr --allow-active-model \
  && [ ! -d "$eng/models/Fake-ASR@222222222222" ] \
  && [ "$(/usr/bin/jq -cS .roles.tts "$eng/install.json")" = "$tts_before" ] \
  && [ "$(/usr/bin/jq -r '.roles | has("asr")' "$eng/install.json")" = false ] \
  && [ "$(/usr/bin/jq -r .profile "$eng/install.json")" = compact16 ] \
  && [ -d "$eng/models/Fake-ASR-Large@333333333333" ] \
  && ok "opt-in active removal preserves TTS and leaves spare ASR inactive" || no "active ASR removal"
inst --add-model fake-asr && [ -d "$eng/models/Fake-ASR@222222222222" ] \
  && [ "$(/usr/bin/jq -r '.roles | has("asr")' "$eng/install.json")" = false ] \
  && ok "removed ASR can be downloaded again without silently activating it" || no "active ASR redownload"
inst --profile standard && [ "$(/usr/bin/jq -r .roles.asr.id "$eng/install.json")" = fake-asr ] \
  && ok "explicit preset restores the removed role" || no "active ASR restore"
before_invalid="$(tt_sha256 "$eng/install.json")"
inst --allow-active-model && no "active removal flag cannot trigger install" || ok "active removal flag cannot trigger install"
[ "$(tt_sha256 "$eng/install.json")" = "$before_invalid" ] \
  && ok "invalid flag usage preserves record" || no "invalid flag mutated record"

inst --profile compact16 && inst --add-model fake-asr-large \
  && [ "$(/usr/bin/jq -r '.roles | has("asr")' "$eng/install.json")" = false ] \
  && [ "$(/usr/bin/jq -r .profile "$eng/install.json")" = compact16 ] \
  && ok "Apple recognition preset stays without active ASR after model add" || no "Apple preset add"
inst --select-tts fake-ming --model-source "$source_m" \
  && [ "$(/usr/bin/jq -r '.roles | has("asr")' "$eng/install.json")" = false ] \
  && [ "$(/usr/bin/jq -r .roles.tts.id "$eng/install.json")" = fake-ming ] \
  && inst --select-tts fake-tts \
  && [ "$(/usr/bin/jq -r .profile "$eng/install.json")" = compact16 ] \
  && ok "switching TTS preserves intentionally absent ASR and restores its preset on return" || no "TTS Apple recognition preservation"
inst --remove-model fake-ming
inst --profile standard
asr_before="$(/usr/bin/jq -cS .roles.asr "$eng/install.json")"
inst --remove-model fake-tts --allow-active-model \
  && [ ! -d "$eng/models/Fake-TTS@111111111111" ] \
  && [ "$(/usr/bin/jq -cS .roles.asr "$eng/install.json")" = "$asr_before" ] \
  && [ "$(/usr/bin/jq -r '.roles | has("tts")' "$eng/install.json")" = false ] \
  && [ "$(/usr/bin/jq -r .profile "$eng/install.json")" = custom ] \
  && ok "opt-in active TTS removal preserves ASR and records custom composition" || no "active TTS removal"
set_record '.profile = "max"'
asr_before="$(/usr/bin/jq -cS .roles.asr "$eng/install.json")"
inst && [ "$(/usr/bin/jq -cS .roles.asr "$eng/install.json")" = "$asr_before" ] \
  && [ "$(/usr/bin/jq -r .roles.tts.id "$eng/install.json")" = fake-tts ] \
  && ok "implicit completion of ASR-only custom setup adds only TTS" || no "custom resource completion"
inst --remove-model fake-tts --allow-active-model
roles_before="$(/usr/bin/jq -cS .roles "$eng/install.json")"
inst --add-model fake-asr-large && [ "$(/usr/bin/jq -cS .roles "$eng/install.json")" = "$roles_before" ] \
  && [ "$(/usr/bin/jq -r .profile "$eng/install.json")" = custom ] \
  && ok "adding a model preserves custom active roles" || no "custom add"
inst --remove-model fake-asr && no "custom active role also requires opt-in" || ok "custom active role also requires opt-in"
inst --remove-model fake-asr --allow-active-model && [ "$(/usr/bin/jq -r '.roles | length' "$eng/install.json")" = 0 ] \
  && [ "$(/usr/bin/jq -r .profile "$eng/install.json")" = custom ] \
  && ok "custom role removal does not activate another downloaded model" || no "custom remove"
inst --profile standard
inst --remove-model fake-asr-large

# Recognition preparation preserves a custom voice and larger selected ASR, even
# when the selected compatible revision is older than the current download pin.
inst --profile max
inst --select-tts fake-ming
roles_before="$(/usr/bin/jq -cS .roles "$eng/install.json")"
models_before="$(/usr/bin/jq -cS .models "$eng/install.json")"
inst --recognition-only && [ "$(/usr/bin/jq -cS .roles "$eng/install.json")" = "$roles_before" ] \
  && [ "$(/usr/bin/jq -cS .models "$eng/install.json")" = "$models_before" ] \
  && ! /usr/bin/grep -q '^--tts$' "$work/smoke_args" \
  && ok "recognition retains custom TTS and larger ASR without synthesizing" || no "recognition preserves selected models"
record_before="$(tt_sha256 "$eng/install.json")"
/bin/mv "$eng/models/Fake-Ming@444444444444/config.json" "$work/ming-config"
inst --recognition-only && no "recognition rejects a broken preserved TTS role" || ok "recognition rejects a broken preserved TTS role"
[ "$(tt_sha256 "$eng/install.json")" = "$record_before" ] && [ ! -e "$eng/install.json.prev" ] \
  && /usr/bin/grep -q 'repair speech resources first' "$work/err" \
  && ok "broken preserved role gives actionable failure before mutation" || no "preserved role failure state"
/bin/mv "$work/ming-config" "$eng/models/Fake-Ming@444444444444/config.json"
printf '\nTT_M_FAKE_ASR_LARGE_REVISION="6666666666666666666666666666666666666666"\nTT_M_FAKE_ASR_LARGE_COMPAT_REVISIONS="%s"\n' "$rev_large" >> "$tree/scripts/lib/versions.sh"
inst --recognition-only && [ "$(/usr/bin/jq -cS .roles "$eng/install.json")" = "$roles_before" ] \
  && [ "$(/usr/bin/jq -cS .models "$eng/install.json")" = "$models_before" ] \
  && [ ! -e "$eng/models/Fake-ASR-Large@666666666666" ] \
  && /usr/bin/grep -q "^$rev_large$" "$work/smoke_args" \
  && ok "recognition reuses the selected compatible ASR revision" || no "recognition compatible revision"
printf '\nTT_M_FAKE_ASR_LARGE_REVISION="%s"\n' "$rev_large" >> "$tree/scripts/lib/versions.sh"
inst --remove-model fake-ming --allow-active-model
asr_before="$(/usr/bin/jq -cS .roles.asr "$eng/install.json")"
inst && [ "$(/usr/bin/jq -cS .roles.asr "$eng/install.json")" = "$asr_before" ] \
  && [ "$(/usr/bin/jq -r .roles.tts.id "$eng/install.json")" = fake-tts ] \
  && ok "later speech setup retains the selected larger ASR" || no "larger ASR speech upgrade"
inst --profile standard
inst --remove-model fake-asr-large

# 8. uninstall keeps foreign files
printf 'mine' > "$eng/models/Fake-TTS@111111111111/notes.txt"
inst --uninstall --json-progress && ok "uninstall exits 0" || no "uninstall"
[ -f "$eng/models/Fake-TTS@111111111111/notes.txt" ] && [ ! -d "$eng/models/Fake-ASR@222222222222" ] \
  && [ ! -e "$eng/venv" ] && [ ! -e "$eng/python" ] && [ ! -e "$eng/install.json" ] \
  && ok "uninstall removes owned files, keeps the foreign one" || no "uninstall foreign"
/usr/bin/grep -q 'keeping .*Fake-TTS' "$work/err" && ok "kept directory reported" || no "keep warning"
/bin/rm -f "$eng/models/Fake-TTS@111111111111/notes.txt"
inst --uninstall && [ ! -e "$eng" ] && ok "second uninstall removes the engine home" || no "engine home removed"

# 9. SIGTERM: interrupted event, exit 130, lock released, re-run resumes
/bin/mkdir -p "$eng/warmup"; for f in ref-zh.wav ref-zh.txt sample-zh.wav sample-zh.txt; do printf 'x' > "$eng/warmup/$f"; done
: > "$work/venv_sleep"
inst --json-progress & runner=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$eng/venv" ] || [ -e "$eng/python" ] && break; /bin/sleep 0.2; done
/bin/sleep 0.3
installer_pid="$(/usr/bin/readlink "$eng/.lock" 2>/dev/null || true)"
[ -n "$installer_pid" ] && /bin/kill -TERM "$installer_pid"
rc=0; wait "$runner" || rc=$?
[ "$rc" = "130" ] && ok "SIGTERM exits 130" || no "SIGTERM rc=$rc"
/usr/bin/grep -q '"message":"interrupted"' "$work/out" && ok "interrupted event emitted" || no "interrupted event"
[ ! -e "$eng/.lock" ] && ok "lock released after SIGTERM" || no "lock after SIGTERM"
/bin/rm -f "$work/venv_sleep"
inst && inst --check && ok "re-run after SIGTERM completes" || no "resume after SIGTERM"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
