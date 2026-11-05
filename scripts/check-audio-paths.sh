#!/bin/bash
# check-audio-paths.sh: static rules for the only microphone -> output path (ARCHITECTURE.md §3.8
# "静态规则", privacy invariant 1). Microphone samples reach an output only through
#   ringM -> PassthroughGate.admit -> PassthroughStage -> ringP -> feedIOProc -> Feed channel 1,
# so the names on that path may appear only in the files that own each step.
#   scripts/check-audio-paths.sh          check this checkout's Sources/
#   scripts/check-audio-paths.sh <root>   check <root>/Sources/ (the fixture tests use this)
# Comments are ignored: /* ... */ blocks (across lines and inline; nested in Swift) and // to the
# end of the line, recognized only outside string, character, raw string and regex literals
# ("voices/*.wav", #"https://x"#, "\(f("/*"))" are not comments), with each file's own language
# rules (Swift for .swift, C for the rest; see the scanner below). Preprocessor lines (#define,
# #if) and lines starting with * outside a block are code.
# Exit 1 on any violation.
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
src="$root/Sources"
[ -d "$src" ] || { echo "check-audio-paths: no $src" >&2; exit 2; }

# id | allow (the pattern may appear only in paths matching) or deny (never in paths matching) |
# grep -E pattern | path regex (relative to root) | what it protects
rules() {
  /bin/cat <<'EOF'
AP1|allow|tt_mic_ctx_create[[:space:]]*\(|^Sources/TalkTalkAudio/MicCapture\.swift$|^Sources/CAudioCore/|the mic ring (ringM) is created only by MicCapture
AP2|allow|MicCapture[[:space:]]*\(|^Sources/TalkTalkAudio/(MicCapture|MicIngest)\.swift$|^Sources/TalkTalkVoice/EnrollmentController\.swift$|^Sources/TalkTalkApp/Bench[A-Za-z]*\.swift$|^Sources/TalkTalkApp/PassthroughCalibration\.swift$|ringM is read only by the worker's MicIngest (plus enrollment and dev bench recording, which never reach an output)
AP3|allow|PassthroughFrames[[:space:]]*\(|^Sources/TalkTalkCore/PassthroughGate\.swift$|PassthroughFrames are made only by PassthroughGate.admit
AP4|allow|tt_ringp_write|^Sources/TalkTalkAudio/PassthroughStage\.swift$|^Sources/CAudioCore/(tt_ringp\.c|include/tt_ringp\.h)$|only PassthroughStage writes ringP
AP5|allow|tt_ringp_read|^Sources/CAudioCore/(tt_ioproc_feed\.c|tt_ringp\.c|include/tt_ringp\.h)$|only feedIOProc reads ringP
AP6|allow|TTSChunk[[:space:]]*\(|^Sources/TalkTalkEngineHost/RemoteQwen(TTS|\+[A-Za-z]+)\.swift$|^Sources/[A-Za-z]+/SystemVoiceTTS\.swift$|TTSChunk comes only from the two TTS engines (RemoteQwenTTS and its RemoteQwen+*.swift parts, SystemVoiceTTS)
AP7|deny|PassthroughFrames|^Sources/[A-Za-z]+/(MonitorOutput|ClauseQueue|PlayoutStage)\.swift$|Monitor|^Sources/CAudioCore/(tt_ring\.c|include/tt_ring\.h|tt_ioproc_monitor\.c)$|MonitorOutput and the ringO files never take PassthroughFrames
AP8|allow|(var|let|func)[[:space:]]+feedChannel|PassthroughSource[[:space:]]*\(rawValue|^Sources/TalkTalkCore/PassthroughGate\.swift$|the .mic<->ch1 / .selfTest<->ch2 binding exists only in PassthroughGate
AP9|allow|origin:[[:space:]]*\.selfTest|setSource[[:space:]]*\([[:space:]]*\.selfTest|openSelfTest[[:space:]]*\(|^Sources/TalkTalkCore/PassthroughGate\.swift$|^Sources/[A-Za-z]+/[A-Za-z]*SelfTest[A-Za-z]*\.swift$|only self-test code routes passthrough to channel 2
AP11|deny|FeedOutput|ClauseQueue|PlayoutRing|PlayoutStage|tt_ring_write|tt_ioproc_feed|tt_feed_|^Sources/TalkTalkVoice/|^Sources/TalkTalkApp/SelfTestVoice\.swift$|the audition reaches only the monitor output, never the Feed / TalkTalk Mic
AP10|allow|tt_ringp_[a-z_]+|^Sources/CAudioCore/(tt_ringp\.c|include/tt_ringp\.h|tt_ioproc_feed\.c)$|^Sources/TalkTalkAudio/(PassthroughStage|FeedOutput)\.swift$|the ringP API is used only by its owners
EOF
}

files() {
  # every source kind SwiftPM compiles in a Swift or C-family target
  /usr/bin/find "$src" -type f \( -name '*.swift' -o -name '*.c' -o -name '*.h' -o -name '*.m' -o -name '*.mm' \
    -o -name '*.cpp' -o -name '*.cc' -o -name '*.cxx' -o -name '*.hpp' -o -name '*.hh' -o -name '*.s' -o -name '*.S' \) \
    | LC_ALL=C /usr/bin/sort
}

# A character-level scanner, run per file, with a stack of contexts. The lexical rules follow the
# file's language (-v swift=1 for .swift, C-family rules for everything else):
#   C  code (top level, or a Swift "\(...)" interpolation counting its parentheses); a backslash
#      in code escapes the next character (a bare Swift /\"/ regex, a C line splice)
#   S  a string. Swift: "...", """ (opening only at the end of its line) and raw #"..."# /
#      #"""..."""# with any number of # (in a raw string a backslash is literal unless followed by
#      the same number of #), with \( interpolation. C: "..." only, a backslash escapes the next
#      character and a backslash at the end of a line continues the string on the next line.
#   Q  a C character literal '...' (C only)
#   X  a Swift extended regex literal #/.../#
#   R  a C++ raw string R"delim(...)delim" (also u8R, LR, uR, UR; C only)
#   B  a /* */ block comment, nested in Swift (/* /* */ */ is one comment), not in C
# Multi-line strings, raw strings, regex literals opened at the end of a line, continued C
# strings and block comments carry their state across lines; other one-line literals end with
# their line. Comment markers count only in code; string contents stay in the scanned text (a
# restricted name inside a string is still a use). Known limit: a bare Swift /regex/ is scanned
# as code, so an unescaped " or /* inside one (/[/*]/) still reads as a string or comment start;
# write such a regex as #/.../#.
scanner="$(/bin/cat <<'AWK'
function push(t, h, m, d) { sp++; ty[sp] = t; hh[sp] = h; mm[sp] = m; dl[sp] = d; pd[sp] = 0; ip[sp] = 0; ct[sp] = 0 }
function hashes(s, i,   k) { k = 0; while (substr(s, i + k, 1) == "#") k++; return k }
function rep(c, n,   r) { r = ""; while (n-- > 0) r = r c; return r }
BEGIN { sp = 1; ty[1] = "C"; ip[1] = 0; pd[1] = 0; ct[1] = 0; q = "\"" }
{ line = $0; out = ""; n = length(line); i = 1
  for (k = 2; k <= sp; k++)   # one-line literals (and anything inside them) end with their line
    if ((((ty[k] == "S" || ty[k] == "X") && !mm[k]) || ty[k] == "Q") && !ct[k]) { sp = k - 1; break }
  for (k = 2; k <= sp; k++) ct[k] = 0
  while (i <= n) {
    ch = substr(line, i, 1); t = ty[sp]
    if (t == "B") {
      two = substr(line, i, 2)
      if (two == "*/") { sp--; out = out " "; i += 2 }
      else if (swift && two == "/*") { push("B", 0, 0, ""); i += 2 }
      else i++
      continue
    }
    if (t == "S") {
      h = hh[sp]; term = (mm[sp] ? q q q : q) rep("#", h)
      if (substr(line, i, length(term)) == term) { out = out term; i += length(term); sp--; continue }
      if (ch == "\\" && substr(line, i + 1, h) == rep("#", h)) {
        j = i + 1 + h
        if (j > n) { if (!swift) ct[sp] = 1; out = out substr(line, i); i = j; continue }   # C: continues
        out = out substr(line, i, j - i + 1)
        if (swift && substr(line, j, 1) == "(") { i = j + 1; push("C", 0, 0, ""); ip[sp] = 1; continue }
        i = j + 1; continue          # an escape: the escaped character goes with it
      }
      out = out ch; i++; continue
    }
    if (t == "Q") {
      out = out ch
      if (ch == "\\") { if (i == n) ct[sp] = 1; out = out substr(line, i + 1, 1); i += 2; continue }
      if (ch == "'") sp--
      i++; continue
    }
    if (t == "R") {
      term = ")" dl[sp] q
      if (substr(line, i, length(term)) == term) { out = out term; i += length(term); sp--; continue }
      out = out ch; i++; continue
    }
    if (t == "X") {
      term = "/" rep("#", hh[sp])
      if (substr(line, i, length(term)) == term) { out = out term; i += length(term); sp--; continue }
      if (ch == "\\") { out = out substr(line, i, 2); i += 2; continue }
      out = out ch; i++; continue
    }
    # code
    if (ip[sp]) {
      if (ch == "(") pd[sp]++
      else if (ch == ")") {
        if (pd[sp] == 0) { sp--; out = out ch; i++; continue }
        pd[sp]--
      }
    }
    two = substr(line, i, 2)
    if (two == "//") break
    if (two == "/*") { push("B", 0, 0, ""); out = out " "; i += 2; continue }
    if (ch == "\\") { out = out two; i += 2; continue }
    if (!swift) {
      if (ch == q) { push("S", 0, 0, ""); out = out ch; i++; continue }
      if (ch == "'") { push("Q", 0, 0, ""); out = out ch; i++; continue }
      if (ch == "R" && substr(line, i + 1, 1) == q) {
        pre = substr(line, 1, i - 1)
        if (pre ~ /[^A-Za-z0-9_]/) sub(/.*[^A-Za-z0-9_]/, "", pre)
        if (pre == "" || pre == "u8" || pre == "L" || pre == "u" || pre == "U") {
          k = index(substr(line, i + 2), "(")
          d = k > 0 ? substr(line, i + 2, k - 1) : ""
          if (k > 0 && k <= 17 && d !~ /[ ()\\\t]/) { push("R", 0, 0, d); out = out substr(line, i, k + 2); i = i + 2 + k; continue }
        }
      }
      out = out ch; i++; continue
    }
    if (ch == "#" || ch == q) {
      h = hashes(line, i); j = i + h
      if (substr(line, j, 3) == q q q && substr(line, j + 3) ~ /^[[:space:]]*$/) {
        push("S", h, 1, ""); out = out substr(line, i, h + 3); i = j + 3; continue
      }
      if (substr(line, j, 1) == q) { push("S", h, 0, ""); out = out substr(line, i, h + 1); i = j + 1; continue }
      if (h > 0 && substr(line, j, 1) == "/") {
        rest = substr(line, j + 1)
        push("X", h, rest ~ /^[[:space:]]*$/, ""); out = out substr(line, i, h + 1); i = j + 1; continue
      }
      out = out substr(line, i, h); i = j; continue   # #if, #selector, ...
    }
    out = out ch; i++
  }
  if (out ~ /^[[:space:]]*$/) next
  print rel ":" NR ":" out
}
AWK
)"

# Print "rel:line:code" for code (not comment) lines of every source file.
code_lines() {
  local f rel sw
  while IFS= read -r f; do
    rel="${f#"$root"/}"
    case "$f" in *.swift) sw=1 ;; *) sw=0 ;; esac
    /usr/bin/awk -v rel="$rel" -v swift="$sw" "$scanner" "$f"
  done < <(files)
}

all="$(code_lines)"
violations=0
count=0
while IFS='|' read -r id mode rest; do
  [ -n "$id" ] || continue
  count=$((count + 1))
  # The pattern and path regex may contain '|' alternatives: the last field is the message,
  # the field before it the paths; everything between mode and paths is the pattern. Patterns
  # and path regexes are split on the first field that starts with '^'.
  why="${rest##*|}"
  body="${rest%|*}"
  pattern="${body%%|^*}"
  paths="${body#"$pattern"|}"
  # ENVIRON, not -v: awk would process the backslashes of a -v value as string escapes.
  hits="$(printf '%s\n' "$all" | TT_PAT="$pattern" /usr/bin/awk '
    { i = index($0, ":"); j = index(substr($0, i + 1), ":"); code = substr($0, i + j + 1)
      if (code ~ ENVIRON["TT_PAT"]) print }')"
  [ -n "$hits" ] || continue
  while IFS= read -r hit; do
    rel="${hit%%:*}"
    inside=0
    if printf '%s\n' "$rel" | /usr/bin/grep -Eq "$paths"; then inside=1; fi
    if { [ "$mode" = allow ] && [ "$inside" = 0 ]; } || { [ "$mode" = deny ] && [ "$inside" = 1 ]; }; then
      printf '%s: %s\n  %s\n' "$id" "$why" "$hit"
      violations=$((violations + 1))
    fi
  done <<< "$hits"
done < <(rules)

if [ "$violations" -gt 0 ]; then
  printf 'check-audio-paths: %d violation(s)\n' "$violations"
  exit 1
fi
printf 'check-audio-paths: ok (%d rules)\n' "$count"
