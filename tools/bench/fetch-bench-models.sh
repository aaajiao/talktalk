#!/bin/bash
# fetch-bench-models.sh: download and verify M0 bench models into the bench directory
# (ARCHITECTURE.md §14 M0 day 1). Same pins / .part resume / per-file sha256 / .talktalk-verified
# discipline as scripts/install-engine.sh (shared code: scripts/lib/models.sh).
#
#   fetch-bench-models.sh --list                 keys, sizes, installed or not (no network)
#   fetch-bench-models.sh [key ...]              default: the bench-only models in bench-pins.sh
#   fetch-bench-models.sh --check [key ...]      full sha256 verification, exit 0/1
#
# Bench dir: ~/Library/Application Support/TalkTalk-bench/ (override: TALKTALK_BENCH_HOME, tests only).
# Formal models needed only by a bench (asr-qwen3-1.7b-8bit for T5) may also be fetched here by key.
# Network: huggingface.co only. Never touches ~/.readread, the Keychain or the TalkTalk engine dir.
set -euo pipefail
umask 077

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
. "$root/scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/versions.sh
. "$root/scripts/lib/versions.sh"
# shellcheck source=bench-pins.sh
. "$here/bench-pins.sh"
# shellcheck source=../../scripts/lib/models.sh
. "$root/scripts/lib/models.sh"

BENCH_HOME="${TALKTALK_BENCH_HOME:-$HOME/Library/Application Support/TalkTalk-bench}"
MODELS_DIR="$BENCH_HOME/models"
HF_BASE="${TALKTALK_TEST_HF_BASE:-https://huggingface.co}"
CURL_PROTO_OK=1
if [ -n "${TALKTALK_TEST_HF_BASE:-}" ]; then CURL_PROTO_OK=0; fi
TT_MODELS="$TT_MODELS $TB_BENCH_MODELS"
tt_assert_safe_dir "$BENCH_HOME"

op="fetch"
case "${1:-}" in
  --list) op="list"; shift ;;
  --check) op="check"; shift ;;
  -h|--help) /usr/bin/sed -n '2,13p' "$0"; exit 0 ;;
esac
keys="$*"
[ -n "$keys" ] || keys="$TB_BENCH_MODELS"

LOCK_DIR="$BENCH_HOME/.lock.d"
acquire() {
  /bin/mkdir -p "$BENCH_HOME"
  /bin/mkdir "$LOCK_DIR" 2>/dev/null && { printf '%s' "$$" > "$LOCK_DIR/pid"; return 0; }
  local other; other="$(/bin/cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$other" ] && /bin/kill -0 "$other" 2>/dev/null; then tt_die "another fetch is running (pid $other)"; fi
  tt_warn "taking over stale lock (pid ${other:-?})"
  printf '%s' "$$" > "$LOCK_DIR/pid"
}
release() { [ "$(/bin/cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && /bin/rm -rf "$LOCK_DIR"; return 0; }

case "$op" in
  list)
    for k in $TT_MODELS; do
      state="missing"; model_quick_ok "$k" && state="installed"
      printf '%-36s %12s bytes  %-9s %s\n' "$k" "$(tt_model_bytes "$k")" "$state" "$(tt_model_field "$k" REPO)"
    done ;;
  check)
    bad=0
    for k in $keys; do check_model_key "$k"; if model_full_verify "$k"; then tt_log "$k: ok"; else bad=1; fi; done
    exit "$bad" ;;
  fetch)
    acquire; trap release EXIT; trap 'tt_log "interrupted; re-run to resume"; exit 130' INT TERM HUP
    need=0
    for k in $keys; do check_model_key "$k"; need=$((need + $(model_missing_bytes "$k"))); done
    need=$((need + need / 10)); free="$(tt_free_bytes "$BENCH_HOME")"
    tt_log "disk: need $need bytes (incl. 10%), free $free"
    [ "$free" -ge "$need" ] || tt_die "not enough disk space"
    /bin/mkdir -p "$MODELS_DIR"
    for k in $keys; do install_model "$k"; done
    # keep the bench dir out of Time Machine (it is ~10 GB of re-downloadable data)
    /usr/bin/tmutil addexclusion "$BENCH_HOME" 2>/dev/null || true
    tt_log "bench models ready in $MODELS_DIR" ;;
esac
