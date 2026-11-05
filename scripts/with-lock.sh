#!/bin/bash
# with-lock.sh: run a command while holding one of the shared machine locks, so parallel
# sessions do not build on the same slot, load the GPU together, or fight over audio devices.
#
#   scripts/with-lock.sh build <1|2|3|4> -- <command...>   one of four build slots
#   scripts/with-lock.sh gpu -- <command...>                GPU work (MLX, engine runs)
#   scripts/with-lock.sh device -- <command...>             audio device / driver / coreaudiod work
#   scripts/with-lock.sh quiet -- <command...>              a quiet machine for measurements:
#                                                           takes build 1→2→3→4, then gpu
#
# Locks are /usr/bin/lockf -k on files in $TT_LOCK_DIR (default /private/tmp/claude):
# talktalk-build-{1,2,3,4}.lock, talktalk-gpu.lock, talktalk-device.lock. Every holder takes
# locks in the same order (build slots ascending, then gpu), so quiet cannot deadlock against
# another holder. The directory is created when missing (/private/tmp/claude is gone after a
# reboot). The command's exit status is returned unchanged.
#
# Nesting order when one job needs more than one lock (e.g. a measurement on the audio device):
# take quiet or gpu FIRST, then device, never the other way round:
#   scripts/with-lock.sh quiet -- scripts/with-lock.sh device -- <command...>
# Two sessions that nest in opposite orders can deadlock each other. Build slots come before
# gpu (quiet already does this).
#
# TT_LOCK_TIMEOUT=<seconds>: give up after that long (lockf -t; 0 = do not wait). lockf then
# exits 75 (EX_TEMPFAIL) without running the command. Unset: wait as long as it takes.
# Exit 2: usage error, or the lock directory cannot be created.
set -euo pipefail

LOCKF=/usr/bin/lockf
dir="${TT_LOCK_DIR:-/private/tmp/claude}"

usage() {
  printf 'usage: %s build <1-4> -- <command...>\n       %s gpu|device|quiet -- <command...>\n' \
    "$0" "$0" >&2
  exit 2
}

[ $# -ge 1 ] || usage
kind="$1"; shift
locks=()
case "$kind" in
  build)
    [ $# -ge 1 ] || usage
    case "$1" in 1|2|3|4) ;; *) usage ;; esac
    locks=("talktalk-build-$1.lock"); shift ;;
  gpu)    locks=("talktalk-gpu.lock") ;;
  device) locks=("talktalk-device.lock") ;;
  quiet)  locks=("talktalk-build-1.lock" "talktalk-build-2.lock" "talktalk-build-3.lock"
                 "talktalk-build-4.lock" "talktalk-gpu.lock") ;;
  *) usage ;;
esac
[ $# -ge 2 ] && [ "$1" = "--" ] || usage
shift

/bin/mkdir -p "$dir" 2>/dev/null || { printf 'with-lock: cannot create lock directory %s\n' "$dir" >&2; exit 2; }

timeout=()
if [ -n "${TT_LOCK_TIMEOUT:-}" ]; then
  case "$TT_LOCK_TIMEOUT" in *[!0-9]*) usage ;; esac
  timeout=(-t "$TT_LOCK_TIMEOUT")
fi

# Nest the lockf calls: lockf -k A lockf -k B ... <command>. Each lockf holds its lock until
# its child (the next lockf, finally the command) exits.
chain=()
for l in "${locks[@]}"; do
  chain+=("$LOCKF" -k ${timeout[@]+"${timeout[@]}"} "$dir/$l")
done
exec "${chain[@]}" "$@"
