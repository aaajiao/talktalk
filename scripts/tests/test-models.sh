#!/bin/bash
# shellcheck disable=SC2015  # ok/no always return 0, so "A && ok || no" is a safe if-then-else
# Installer model-path tests against file:// fixtures (no network): install, idempotence,
# .part resume, corrupted file detection, foreign-file refusal, sha mismatch refusal.
# Run: scripts/tests/test-models.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$here/../lib/common.sh"
# shellcheck source=../lib/models.sh
. "$here/../lib/models.sh"

work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tt-models-test.XXXXXX")"
trap '/bin/rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
src="$work/hf/acme/fake-model/resolve/0123456789abcdef0123456789abcdef01234567"
/bin/mkdir -p "$src/sub"
printf 'hello config\n' > "$src/config.json"
/bin/dd if=/dev/urandom of="$src/sub/weights.bin" bs=1024 count=256 2>/dev/null

line() { printf '%s %s %s\n' "$1" "$(tt_fsize "$src/$1")" "$(tt_sha256 "$src/$1")"; }
TT_M_FAKE_MODEL_REPO="acme/fake-model"
TT_M_FAKE_MODEL_REVISION="0123456789abcdef0123456789abcdef01234567"
TT_M_FAKE_MODEL_ROLE="tts"; TT_M_FAKE_MODEL_LICENSE="MIT"
TT_M_FAKE_MODEL_FILES="$(line config.json; line sub/weights.bin)"
TT_MODELS="fake-model"; TT_LICENSE_ALLOW="Apache-2.0 MIT"; TT_MODEL_DENY="tencent/HY-MT"
MODELS_DIR="$work/home/models"; HF_BASE="file://$work/hf"; CURL_PROTO_OK=0
export TT_M_FAKE_MODEL_REPO TT_M_FAKE_MODEL_REVISION TT_M_FAKE_MODEL_ROLE TT_M_FAKE_MODEL_LICENSE \
  TT_M_FAKE_MODEL_FILES TT_MODELS TT_LICENSE_ALLOW TT_MODEL_DENY MODELS_DIR HF_BASE CURL_PROTO_OK

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
d="$MODELS_DIR/fake-model@0123456789ab"
# Invert one byte in place. A fixed replacement byte equals the random fixture byte 1 time in 256,
# which left the file unchanged and made the corruption check fail by chance.
flip_byte() { # file offset
  _b="$(/usr/bin/od -An -tu1 -j"$2" -N1 "$1" | /usr/bin/tr -d ' ')"
  printf '%b' "\\0$(printf '%03o' $((_b ^ 255)))" | /bin/dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null
}

( install_model fake-model ) 2>/dev/null && [ -f "$d/.talktalk-verified" ] \
  && [ "$(/usr/bin/head -1 "$d/.talktalk-verified")" = "$TT_M_FAKE_MODEL_REVISION" ] && ok "fresh install writes .talktalk-verified" || no "fresh install"
model_quick_ok fake-model && ok "quick check passes" || no "quick check"
model_full_verify fake-model 2>/dev/null && ok "full verify passes" || no "full verify"
out="$( ( install_model fake-model ) 2>&1)"; case "$out" in *"already installed"*) ok "re-run is a no-op" ;; *) no "re-run no-op" ;; esac

flip_byte "$d/sub/weights.bin" 100
model_full_verify fake-model 2>/dev/null && no "corruption detected" || ok "corruption detected by full verify"

/bin/rm -rf "$d"; /bin/mkdir -p "$d/sub"
/usr/bin/head -c 1000 "$src/sub/weights.bin" > "$d/sub/weights.bin.part"
( install_model fake-model ) 2>/dev/null && /usr/bin/cmp -s "$d/sub/weights.bin" "$src/sub/weights.bin" \
  && [ ! -e "$d/sub/weights.bin.part" ] && ok ".part resumes to a verified file" || no ".part resume"

/bin/rm -f "$d/.talktalk-verified"; printf 'x' > "$d/stray.txt"
( install_model fake-model ) 2>/dev/null && no "foreign file refused" || ok "foreign file refused"
[ -f "$d/stray.txt" ] && ok "foreign file left in place" || no "foreign file kept"
/bin/rm -f "$d/stray.txt"

/bin/rm -rf "$d"
TT_M_FAKE_MODEL_FILES="$(line config.json; printf 'sub/weights.bin %s %s\n' "$(tt_fsize "$src/sub/weights.bin")" "$(printf '0%.0s' $(seq 64))")"
( install_model fake-model ) 2>/dev/null && no "sha mismatch refused" || ok "sha mismatch refused"
[ ! -f "$d/.talktalk-verified" ] && [ ! -e "$d/sub/weights.bin" ] && ok "nothing marked verified after mismatch" || no "no stamp after mismatch"

TT_M_FAKE_MODEL_REPO="tencent/HY-MT-x"
( check_model_key fake-model ) 2>/dev/null && no "deny list" || ok "deny list enforced"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
