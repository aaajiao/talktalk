#!/bin/bash
# Run the M0-T8 measurements against the installed TalkTalkAudio.driver.
#
#   tools/bench/driver/run-t8.sh <test>... [--out FILE]
#
# Tests: list probe loopback1 loopback2 replay visibility soak60 d1 d2 d4 d5 d6
# M2 'ttmm' (CanBeDefaultDevice switch, driver >= 0.2.0): ttmm-gate m2a d2t d4t
#   (use --out tools/bench/driver/results/m2-ttmm-<date>.jsonl for those)
# Everything that reads TalkTalk Mic / Test Mic is launched through LaunchServices
# (`open -W -n`), so the microphone TCC prompt, if any, is for TTDriverBench
# (com.aaajiao.talktalk.dev), not for the terminal. Results are JSON lines appended to
# tools/bench/driver/results/t8-<date>.jsonl by default.
#
# Needs: driver installed (scripts/driver/install-driver.sh), clients built
# (tools/bench/driver/build.sh). Must run outside any sandbox (coreaudiod access, `open`).
# d1-d6 change the system default input and restore it; the default output is never written.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
B="$ROOT/build/bench-driver"
APP="$B/TTDriverBench.app"
OUT="$ROOT/tools/bench/driver/results/t8-$(date +%Y-%m-%d).jsonl"

tests=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        *) tests+=("$1"); shift ;;
    esac
done
[[ ${#tests[@]} -gt 0 ]] || { sed -n '2,18p' "$0"; exit 2; }
mkdir -p "$(dirname "$OUT")"

direct() { "$APP/Contents/MacOS/ttdrv" "$@" >> "$OUT"; }
viaopen() {
    local err
    err="$(mktemp -t ttdrv-err)"
    open -W -n --stderr "$err" -a "$APP" --args "$@" --out "$OUT"
    if [[ -s "$err" ]]; then
        sed 's/^/ttdrv stderr: /' "$err" >&2
    fi
    rm -f "$err"
}
# visibility / d2: the tester must not itself be an allowed Feed client (every CoreAudio process
# is a HAL client of every device), so it runs as FeedProbe.app (refused by the gate, like a
# meeting app) and only its "hold" children run from TTDriverBench.app (the talktalk stand-in).
asprobe() {
    local err
    err="$(mktemp -t ttdrv-err)"
    open -W -n --stderr "$err" -a "$B/FeedProbe.app" --args "$@" --hold-exe "$APP/Contents/MacOS/ttdrv" --out "$OUT"
    if [[ -s "$err" ]]; then
        sed 's/^/ttdrv stderr: /' "$err" >&2
    fi
    rm -f "$err"
}
mark() { printf '{"t_ms":0,"kind":"tt.run","test":"%s","at":"%s"}\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT"; }

for t in "${tests[@]}"; do
    mark "$t"
    echo "run-t8: $t" >&2
    case "$t" in
        list) direct list ;;
        probe)
            "$B/FeedProbe.app/Contents/MacOS/ttdrv" probe >> "$OUT"
            "$B/ttdrv" probe >> "$OUT"
            direct probe ;;
        loopback1) viaopen loopback --channel 1 ;;
        loopback2) viaopen loopback --channel 2 ;;
        replay) viaopen replay --cycles 20 ;;
        visibility) asprobe visibility ;;
        soak60) viaopen soak --minutes 60 ;;
        soak1) viaopen soak --minutes 1 ;;
        d1) viaopen d1 ;;
        d2) asprobe d2 --runs 5 ;;
        d4) viaopen d4 --wait 120 ;;
        d5) viaopen d5 --seconds 30 ;;
        d6) viaopen d6 ;;
        ttmm-gate)
            # refused: FeedProbe.app and the bare binary are not accepted Feed clients
            "$B/FeedProbe.app/Contents/MacOS/ttdrv" ttmm set 1 >> "$OUT"
            "$B/ttdrv" ttmm set 1 >> "$OUT"
            # accepted: TTDriverBench (com.aaajiao.talktalk.dev); 1 then back to 0
            direct ttmm set 1
            direct ttmm set 0 ;;
        m2a) viaopen m2a ;;
        d2t) asprobe d2 --ttmm --runs 5 ;;
        d4t) viaopen d4 --ttmm --wait 300 ;;
        *) echo "run-t8: unknown test $t" >&2; exit 2 ;;
    esac
done
echo "run-t8: results in $OUT" >&2
