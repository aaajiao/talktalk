#!/bin/bash
# run-dev.sh: start TalkTalk-Dev.app through LaunchServices, so TCC grants (microphone, system
# audio recording, Input Monitoring, Accessibility) belong to the app, not to the terminal (§2.2).
#
#   scripts/run-dev.sh [--build] [--no-wait] [--print] [-- ] [app args...]
#
#   --build     run scripts/build-app.sh dev first
#   --no-wait   do not wait for the app to quit (default: open -W waits)
#   --print     print the open command instead of running it
#   app args    passed to the app (--self-test …, --bench …, --smoke-ui …)
#
# Uses an absolute app path (`open -a` with a relative path fails: "Unable to find application
# named"). A relative `--out FILE` is made absolute (the app's cwd is /); when the app has quit
# and wrote FILE during this run, it is printed. `open` does not work inside the Claude Code
# sandbox: run this from a normal terminal. Exit status: open's (the app's result is in --out).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/TalkTalk-Dev.app"

build=0; wait=1; print=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build) build=1; shift ;;
    --no-wait) wait=0; shift ;;
    --print) print=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

args=(); out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--out" ] && [ $# -ge 2 ]; then
    case "$2" in /*) out="$2" ;; *) out="$PWD/$2" ;; esac
    args+=("--out" "$out"); shift 2
  else
    args+=("$1"); shift
  fi
done

if [ "$build" = 1 ]; then "$root/scripts/build-app.sh" dev; fi
if [ "$print" = 0 ] && [ ! -d "$app" ]; then
  printf 'run-dev: %s not found (scripts/build-app.sh dev, or pass --build)\n' "$app" >&2
  exit 2
fi

cmd=(/usr/bin/open -n)
[ "$wait" = 1 ] && cmd+=(-W)
cmd+=(-a "$app")
[ ${#args[@]} -gt 0 ] && cmd+=(--args "${args[@]}")

if [ "$print" = 1 ]; then
  printf '%q ' "${cmd[@]}"; printf '\n'
  exit 0
fi
before=""
[ -n "$out" ] && [ -f "$out" ] && before="$(/usr/bin/stat -f %m:%z "$out")"
rc=0
"${cmd[@]}" || rc=$?
# Print --out only when the app wrote it during this run.
if [ "$wait" = 1 ] && [ -n "$out" ] && [ -f "$out" ] && [ "$(/usr/bin/stat -f %m:%z "$out")" != "$before" ]; then
  /bin/cat "$out"
fi
exit "$rc"
