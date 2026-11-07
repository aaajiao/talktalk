#!/bin/bash
# check.sh: the project's validation run (lint + generated-file sync + unit tests).
#   scripts/check.sh            everything
#   scripts/check.sh --no-swift skip swift build/test (e.g. inside a sandbox that blocks SwiftPM)
#   scripts/check.sh --skip-stress keep functional checks, skip high-iteration Swift stress/fuzz
# The two flags may be combined, in either order.
# Needs: scripts/setup-dev-python.sh first, shellcheck, Xcode CLT. No network, GPU, Keychain or models.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift=1
skip_stress=0
for arg in "$@"; do
  case "$arg" in
    --no-swift) swift=0 ;;
    --skip-stress) skip_stress=1 ;;
    *) echo "usage: scripts/check.sh [--no-swift] [--skip-stress]" >&2; exit 2 ;;
  esac
done
"$root/scripts/setup-dev-python.sh" --check
export TALKTALK_DEV_PYTHON="$root/.venv/bin/python3"
export PATH="$root/.venv/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }

step "shellcheck"
# shellcheck disable=SC2046
shellcheck -x -P SCRIPTDIR $(/usr/bin/find scripts tools -name '*.sh' -type f | LC_ALL=C /usr/bin/sort)
echo "ok"

step "generated pins in sync"
scripts/gen-pins.sh --check
scripts/tests/test-gen-pins.sh

step "application build-number reservation (isolated fixtures; no compilation)"
"$TALKTALK_DEV_PYTHON" -I -B scripts/tests/test-app-build.py

step "python compiles"
"$TALKTALK_DEV_PYTHON" -I -B -c 'import sys; [compile(open(f, encoding="utf-8").read(), f, "exec") for f in sys.argv[1:]]' \
  engine/talktalk_engine.py engine/smoke_engine.py engine/talktalk_engine/*.py \
  engine/tests/*.py tools/bench/*.py tools/*.py tools/tests/*.py scripts/*.py scripts/tests/*.py
echo "ok"

step "engine unit tests"
( cd engine && "$TALKTALK_DEV_PYTHON" -I -B -m unittest discover -s tests -t . )

step "installer model tests (file:// fixtures)"
scripts/tests/test-models.sh

step "installer CPython manifest tests"
scripts/tests/test-python-manifest.sh

step "installer end-to-end tests (file:// fixtures)"
scripts/tests/test-installer.sh

step "shared lock helper tests (with-lock.sh)"
scripts/tests/test-with-lock.sh

step "generated expected-duration table in sync"
scripts/gen-expected-duration.sh --check

step "latency_report tests"
( cd tools && "$TALKTALK_DEV_PYTHON" -I -B -m unittest discover -s tests -t . )

step "license gate tests (planted fixtures)"
scripts/tests/test-check-licenses.sh

step "license gate (§2.3, C9)"
scripts/check-licenses.sh -q

step "audio path rules (§3.8) + their fixture tests"
scripts/check-audio-paths.sh
scripts/tests/test-audio-paths.sh

step "driver input-device notifications (no audio IO)"
scripts/tests/test-driver-mic-visibility.sh

step "zh-Hans string catalog (§11)"
scripts/tests/test-check-strings.sh
scripts/check-strings.sh

if [ "$swift" = 1 ]; then
  step "swift build + test"
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
  swift build -Xswiftc -DTALKTALK_DEV
  # CLT 6.4.2 + the default swiftbuild backend do not pass the swift-testing macro plugin
  # (usr/lib/swift/host/plugins/testing) to the compiler: "plugin for module 'TestingMacros'
  # not found". Xcode's toolchain does. Name the directory explicitly when it exists.
  testing_plugins="$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing"
  swift_test_args=(-Xswiftc -DTALKTALK_DEV)
  if [ -d "$testing_plugins" ]; then
    swift_test_args+=(-Xswiftc -plugin-path -Xswiftc "$testing_plugins")
  fi
  if [ "$skip_stress" = 1 ]; then
    # Five SPSC runs, four other high-iteration audio runs, and fresh random gate seeds.
    # Keep saved gate regressions, bounded deterministic coverage, and ordinary integration tests.
    stress_skip='spscStressKeepsSequence|spscStressAccountsForEveryFrame|generationStressNeverPlaysAForbiddenFrame|spscStressThroughPlayoutKeepsEveryFrame|plainSpscStressTenMillionFrames'
    stress_skip+='|snapshotsAreNeverTorn|fuzzOneHundredThousandCyclesKeepsThePrivacyInvariants|producerAndReaderOnTwoThreads|fourProducersKeepTheirOrderAndEveryPushIsAccountedFor'
    stress_skip+='|PassthroughFuzzTests[./]fuzz'
    swift_test_args+=(--skip "$stress_skip")
  fi
  swift test "${swift_test_args[@]}"
fi
printf '\nall checks passed\n'
