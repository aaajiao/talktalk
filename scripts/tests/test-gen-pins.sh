#!/bin/bash
# shellcheck disable=SC2015  # ok/no always return 0, so "A && ok || no" is a safe if-then-else
# gen-pins.sh tests on a copy of scripts/ in a temp root: a good versions.sh generates exactly the
# committed files and --check passes; a Feed selector that is not four printable ASCII characters
# makes both the generation and --check exit 2 without writing anything.
# Run: scripts/tests/test-gen-pins.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tt-gen-pins-test.XXXXXX")"
trap '/bin/rm -rf "$work"' EXIT

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

generated="Sources/TalkTalkCore/Generated/EnginePins.swift Sources/TalkTalkCore/Generated/DriverPins.swift
Driver/Sources/Generated/DriverPins.hpp Driver/Sources/Generated/DriverPins.h .python-version"

# fresh <dir>: a root with scripts/gen-pins.sh and scripts/lib/ copied from the repo
fresh() {
  /bin/mkdir -p "$1/scripts/lib"
  /bin/cp "$repo/scripts/gen-pins.sh" "$1/scripts/"
  /bin/cp "$repo/scripts/lib/"*.sh "$1/scripts/lib/"
}

# status <command...>: prints the exit status (set -e safe)
status() { local s=0; "$@" >/dev/null 2>&1 || s=$?; printf '%s' "$s"; }

same_as_repo() {
  local f
  for f in $generated; do /usr/bin/cmp -s "$1/$f" "$repo/$f" || return 1; done
}

# 1. the real versions.sh
good="$work/good"
fresh "$good"
s="$(status "$good/scripts/gen-pins.sh")"
[ "$s" = 0 ] && ok "generation exits 0" || no "generation exited $s"
same_as_repo "$good" && ok "generated files equal the committed ones" || no "generated files differ from the committed ones"
s="$(status "$good/scripts/gen-pins.sh" --check)"
[ "$s" = 0 ] && ok "--check passes on what it generated" || no "--check exited $s"

# Python tooling reads the same exact runtime pin, and stale tooling hints fail the normal gate.
expected_python="$(. "$good/scripts/lib/versions.sh"; printf '%s' "$TT_PY_VERSION")"
[ "$(/bin/cat "$good/.python-version")" = "$expected_python" ] \
  && ok ".python-version follows TT_PY_VERSION" || no "Python version drift"
printf '0.0.0\n' > "$good/.python-version"
s="$(status "$good/scripts/gen-pins.sh" --check)"
[ "$s" = 1 ] && ok "--check rejects stale .python-version" || no "stale Python hint accepted"
"$good/scripts/gen-pins.sh" >/dev/null 2>&1
[ "$(/bin/cat "$good/.python-version")" = "$expected_python" ] \
  && ok "generation restores the Python tooling pin" || no "Python hint not restored"

# 2. bad selectors: exit 2 from both modes, nothing (re)written
bad_case() { # <name> <variable> <value>
  local dir="$work/$1" s
  fresh "$dir"
  /usr/bin/sed -i '' "s/^$2=\"[^\"]*\"/$2=\"$3\"/" "$dir/scripts/lib/versions.sh"
  /usr/bin/grep -q "^$2=\"$3\"" "$dir/scripts/lib/versions.sh" || { no "$1: fixture not applied"; return; }
  s="$(status "$dir/scripts/gen-pins.sh")"
  [ "$s" = 2 ] && ok "$1: generation exits 2" || no "$1: generation exited $s"
  [ ! -e "$dir/Driver/Sources/Generated/DriverPins.h" ] && [ ! -e "$dir/Sources/TalkTalkCore/Generated/DriverPins.swift" ] \
    && ok "$1: nothing written" || no "$1: files were written"
  # --check against good committed files must fail too (not report "in sync")
  local f
  for f in $generated; do /bin/mkdir -p "$(/usr/bin/dirname "$dir/$f")"; /bin/cp "$repo/$f" "$dir/$f"; done
  s="$(status "$dir/scripts/gen-pins.sh" --check)"
  [ "$s" = 2 ] && ok "$1: --check exits 2" || no "$1: --check exited $s"
}
bad_case five-chars TT_DRIVER_MEETING_MODE_SELECTOR ttmmx
bad_case three-chars TT_DRIVER_DIAG_SELECTOR ttd
bad_case non-ascii TT_DRIVER_MEETING_MODE_SELECTOR "ttmé"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
