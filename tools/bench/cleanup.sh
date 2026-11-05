#!/bin/bash
# cleanup.sh: delete the M0 bench directory (~/Library/Application Support/TalkTalk-bench/).
# Run at the end of M0 (§14). Deletes only files this tooling created: model dirs that carry a
# .talktalk-verified stamp or are pinned in bench-pins.sh/versions.sh, plus bench run outputs.
# Anything else is listed and left in place. Never touches ~/Library/Application Support/TalkTalk.
#
#   cleanup.sh            show what would be deleted (dry run)
#   cleanup.sh --yes      delete
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
. "$root/scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/versions.sh
. "$root/scripts/lib/versions.sh"
# shellcheck source=bench-pins.sh
. "$here/bench-pins.sh"

BENCH_HOME="${TALKTALK_BENCH_HOME:-$HOME/Library/Application Support/TalkTalk-bench}"
tt_assert_safe_dir "$BENCH_HOME"
case "$BENCH_HOME" in */TalkTalk-bench) ;; *) tt_die "refusing: $BENCH_HOME is not a TalkTalk-bench dir" ;; esac
[ -d "$BENCH_HOME" ] || { tt_log "nothing to do: $BENCH_HOME does not exist"; exit 0; }

yes=0; [ "${1:-}" = "--yes" ] && yes=1
known=""
for k in $TT_MODELS $TB_BENCH_MODELS; do known="$known $(tt_model_dirname "$k")"; done

del() { if [ "$yes" = 1 ]; then /bin/rm -rf -- "$1"; tt_log "deleted $1"; else tt_log "would delete $1"; fi; }
kept=0
for d in "$BENCH_HOME"/models/*; do
  [ -e "$d" ] || continue
  b="$(/usr/bin/basename "$d")"
  if [ -d "$d" ] && [ ! -L "$d" ] && { [ -f "$d/.talktalk-verified" ] || tt_in_list "$b" "$known"; }; then del "$d"
  else tt_log "keeping (not ours): $d"; kept=1; fi
done
for sub in runs refs audio t7 cache .lock.d; do [ -e "$BENCH_HOME/$sub" ] && del "$BENCH_HOME/$sub"; done
if [ "$yes" = 1 ]; then
  /bin/rmdir "$BENCH_HOME/models" 2>/dev/null || true
  /bin/rmdir "$BENCH_HOME" 2>/dev/null || { tt_log "left $BENCH_HOME (still has files we did not create)"; kept=1; }
else
  tt_log "dry run; re-run with --yes to delete"
fi
exit "$kept"
