#!/bin/bash
# shellcheck disable=SC2015  # ok/no always return 0, so "A && ok || no" is a safe if-then-else
# shellcheck disable=SC2016  # the sh -c bodies expand $1 in the child on purpose
# with-lock.sh tests on a private lock directory: two concurrent holders of one lock run one
# after the other, different build slots run side by side, quiet excludes every build slot and
# the gpu, timeouts give up with 75, exit codes pass through, bad arguments exit 2, a missing
# lock directory is created.
# Run: scripts/tests/test-with-lock.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wl="$here/../with-lock.sh"

work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tt-with-lock-test.XXXXXX")"
TT_LOCK_DIR="$work/locks"
export TT_LOCK_DIR
unset TT_LOCK_TIMEOUT
/bin/mkdir -p "$TT_LOCK_DIR"
pids=""
cleanup() {
  for p in $pids; do kill "$p" 2>/dev/null || true; done
  /bin/rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# wait_for <file> [tenths]: poll until the file exists (default 5 s).
wait_for() {
  local n=0 max="${2:-50}"
  while [ ! -e "$1" ]; do
    n=$((n + 1)); [ "$n" -le "$max" ] || return 1
    /bin/sleep 0.1
  done
}

# hold <name> <lock args...>: start a holder in the background that touches $work/<name>.in once
# it has the lock and keeps it until $work/<name>.release exists.
hold() {
  local name="$1"; shift
  "$wl" "$@" -- /bin/sh -c 'touch "$1.in"; while [ ! -e "$1.release" ]; do sleep 0.05; done' \
    sh "$work/$name" &
  pids="$pids $!"
  wait_for "$work/$name.in"
}
release() { touch "$work/$1.release"; }

# 1. Two concurrent holders of the same lock are serialized: B must not start before A ends.
for kind in "gpu" "device" "build 3"; do
  log="$work/serial-${kind// /-}.log"
  # shellcheck disable=SC2086  # $kind is "build 3" on purpose
  "$wl" $kind -- /bin/sh -c 'echo A_start >> "$1"; touch "$1.a"; sleep 1; echo A_end >> "$1"' sh "$log" &
  a=$!
  wait_for "$log.a"
  # shellcheck disable=SC2086
  "$wl" $kind -- /bin/sh -c 'echo B_start >> "$1"; echo B_end >> "$1"' sh "$log" &
  b=$!
  wait "$a"; wait "$b"
  got="$(/usr/bin/tr '\n' ' ' < "$log")"
  [ "$got" = "A_start A_end B_start B_end " ] && ok "$kind: concurrent holders serialized" \
    || no "$kind: serialized (log: $got)"
done

# 2. A second holder blocks while the first holds the lock (timeout 0 gives up with 75).
hold g1 gpu
rc=0; TT_LOCK_TIMEOUT=0 "$wl" gpu -- /usr/bin/true 2>/dev/null || rc=$?
[ "$rc" = 75 ] && ok "gpu held: second holder gives up with 75" || no "gpu held: rc=$rc"
rc=0; TT_LOCK_TIMEOUT=0 "$wl" device -- /usr/bin/true || rc=$?
[ "$rc" = 0 ] && ok "gpu held: device lock is independent" || no "device while gpu held: rc=$rc"
release g1; wait_for "$work/g1.release"
rc=0; TT_LOCK_TIMEOUT=5 "$wl" gpu -- /usr/bin/true || rc=$?
[ "$rc" = 0 ] && ok "gpu released: next holder runs" || no "gpu after release: rc=$rc"

# 3. Different build slots do not block each other: the slot-1 holder waits for the slot-2
#    command to run while it still holds slot 1.
rc=0
"$wl" build 1 -- /bin/sh -c 'touch "$1.in"; i=0; while [ ! -e "$1.b2" ]; do i=$((i+1)); [ $i -lt 100 ] || exit 9; sleep 0.05; done' \
  sh "$work/slots" &
a=$!
wait_for "$work/slots.in"
"$wl" build 2 -- /usr/bin/touch "$work/slots.b2"
wait "$a" || rc=$?
[ "$rc" = 0 ] && ok "build 1 and build 2 run side by side" || no "slots overlap: rc=$rc"

# 4. quiet waits for every build slot and the gpu.
for kind in "build 1" "build 2" "build 3" "build 4" "gpu"; do
  n="q-${kind// /-}"
  # shellcheck disable=SC2086
  hold "$n" $kind
  rc=0; TT_LOCK_TIMEOUT=0 "$wl" quiet -- /usr/bin/true 2>/dev/null || rc=$?
  [ "$rc" = 75 ] && ok "quiet waits while $kind is held" || no "quiet vs $kind: rc=$rc"
  release "$n"
done
/bin/sleep 0.3

# 5. While quiet holds, every build slot and the gpu are taken; device is not.
hold quiet quiet
for kind in "build 1" "build 2" "build 3" "build 4" "gpu"; do
  rc=0
  # shellcheck disable=SC2086
  TT_LOCK_TIMEOUT=0 "$wl" $kind -- /usr/bin/true 2>/dev/null || rc=$?
  [ "$rc" = 75 ] && ok "quiet held: $kind waits" || no "quiet held: $kind rc=$rc"
done
rc=0; TT_LOCK_TIMEOUT=0 "$wl" device -- /usr/bin/true || rc=$?
[ "$rc" = 0 ] && ok "quiet held: device is free" || no "quiet held: device rc=$rc"
release quiet
/bin/sleep 0.3

# 6. A queued holder runs once the lock frees up (waits instead of failing when no timeout).
hold w1 build 4
"$wl" build 4 -- /usr/bin/touch "$work/w2.ran" &
w2=$!
/bin/sleep 0.3
[ ! -e "$work/w2.ran" ] && ok "queued holder has not run yet" || no "queued holder ran early"
release w1
rc=0; wait "$w2" || rc=$?
[ "$rc" = 0 ] && [ -e "$work/w2.ran" ] && ok "queued holder runs after release" || no "queued holder: rc=$rc"

# 7. Exit status and arguments pass through unchanged.
rc=0; "$wl" gpu -- /bin/sh -c 'exit 7' || rc=$?
[ "$rc" = 7 ] && ok "exit status passes through" || no "exit status: $rc"
out="$("$wl" device -- /usr/bin/printf '%s|' 'a b' '' 'c')"
[ "$out" = "a b||c|" ] && ok "arguments pass through verbatim" || no "arguments: $out"

# 8. Usage errors exit 2 and run nothing.
for args in "" "gpu" "gpu --" "gpu true" "build -- true" "build 5 -- true" "build x -- true" \
            "nope -- true"; do
  rc=0
  # shellcheck disable=SC2086
  "$wl" $args 2>/dev/null || rc=$?
  [ "$rc" = 2 ] && ok "usage error exits 2: '$args'" || no "usage '$args': rc=$rc"
done
rc=0; TT_LOCK_TIMEOUT=abc "$wl" gpu -- /usr/bin/true 2>/dev/null || rc=$?
[ "$rc" = 2 ] && ok "bad TT_LOCK_TIMEOUT exits 2" || no "bad timeout: rc=$rc"
rc=0; TT_LOCK_DIR="$work/missing/sub" "$wl" gpu -- /usr/bin/touch "$work/created.ran" || rc=$?
[ "$rc" = 0 ] && [ -d "$work/missing/sub" ] && [ -e "$work/created.ran" ] && [ -e "$work/missing/sub/talktalk-gpu.lock" ] \
  && ok "missing lock directory is created" || no "missing dir: rc=$rc"
: > "$work/plainfile"
rc=0; TT_LOCK_DIR="$work/plainfile/sub" "$wl" gpu -- /usr/bin/touch "$work/never.ran" 2>/dev/null || rc=$?
[ "$rc" = 2 ] && [ ! -e "$work/never.ran" ] && ok "uncreatable lock directory exits 2" || no "uncreatable dir: rc=$rc"

wait
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
