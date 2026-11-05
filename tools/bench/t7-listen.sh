#!/bin/bash
# t7-listen.sh: T7-lite blind scoring in the terminal (ARCHITECTURE.md §14 T7, §9.4).
# Plays each clip in scores.csv order and asks for two scores with single key presses:
#   1-5  the score        r  play the clip again        q  save and stop (run again to resume)
# scores.csv is rewritten after every clip, so stopping loses nothing. Rows that already have
# both scores are skipped. key.json is never opened. Audio stays where tts_bench.py put it.
#
# Test hooks: T7_DIR (clip directory), T7_KEYS (a file to read key presses from instead of the
# terminal), T7_PLAYER (the player command; default /usr/bin/afplay).
set -euo pipefail

dir="${T7_DIR:-$HOME/Library/Application Support/TalkTalk-bench/t7}"
csv="$dir/scores.csv"
player="${T7_PLAYER:-/usr/bin/afplay}"
[ -f "$csv" ] || { printf '找不到 %s\n' "$csv" >&2; exit 1; }

if [ -n "${T7_KEYS:-}" ]; then exec 3<"$T7_KEYS"; else exec 3</dev/tty; fi

header=""
files=(); langs=(); s1=(); s2=(); notes=()
n=0
while IFS= read -r line || [ -n "$line" ]; do
  if [ -z "$header" ]; then header="$line"; continue; fi
  [ -n "$line" ] || continue
  IFS=, read -r f l a b c <<EOF
$line
EOF
  files[n]="$f"; langs[n]="$l"; s1[n]="${a:-}"; s2[n]="${b:-}"; notes[n]="${c:-}"
  n=$((n + 1))
done < "$csv"

save() {
  local tmp="$csv.tmp.$$" i=0
  printf '%s\n' "$header" > "$tmp"
  while [ "$i" -lt "$n" ]; do
    printf '%s,%s,%s,%s,%s\n' "${files[i]}" "${langs[i]}" "${s1[i]}" "${s2[i]}" "${notes[i]}" >> "$tmp"
    i=$((i + 1))
  done
  /bin/mv -f "$tmp" "$csv"
}

key() {
  local k=""
  IFS= read -rs -n1 -u 3 k || k=q
  printf '%s' "$k"
}

play() { "$player" "$dir/$1" || printf '  （播放失败：%s）\n' "$1" >&2; }

# ask <prompt> <clip>: prints the chosen score (1-5) on stdout. Returns 1 on q. It runs inside
# $(...), so it must not save or exit itself; the caller does that.
ask() {
  local k
  while :; do
    printf '%s' "$1" >&2
    k="$(key)"
    case "$k" in
      [1-5]) printf '%s\n' "$k" >&2; printf '%s' "$k"; return 0 ;;
      r|R) printf '重听\n' >&2; play "$2" ;;
      q|Q) printf '\n' >&2; return 1 ;;
      *) printf '\n' >&2 ;;
    esac
  done
}

stop() { save; printf '已保存。再运行一次这条命令就从这里接着打。\n'; exit 0; }

printf 'T7 盲听：%d 段。每段播完按两次数字键（1–5）。r = 重听，q = 先停下（已打的分会保存）。\n' "$n"
printf '像不像你：5 = 就是我，3 = 有点像，1 = 完全不像。\n'
printf '口音：5 = 像母语者一样自然，3 = 听得出口音但不影响理解，1 = 口音很重或听不清。\n'

i=0
while [ "$i" -lt "$n" ]; do
  if [ -n "${s1[i]}" ] && [ -n "${s2[i]}" ]; then i=$((i + 1)); continue; fi
  f="${files[i]}"
  case "${langs[i]}" in en) name="英语" ;; de) name="德语" ;; *) name="${langs[i]}" ;; esac
  printf '\n[%d/%d] %s（%s）\n' $((i + 1)) "$n" "$f" "$name"
  play "$f"
  a="$(ask '  像不像你 1–5：' "$f")" || stop
  b="$(ask '  口音自然 1–5：' "$f")" || stop
  s1[i]="$a"; s2[i]="$b"
  save
  i=$((i + 1))
done

printf '\n全部打完，已保存到 %s。\n告诉 Claude「打完了」就行。\n' "$csv"
