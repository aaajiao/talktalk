#!/bin/bash
# check-strings.sh: the zh-Hans string catalog gate (ARCHITECTURE.md §11: 文案用中文，开发语言
# zh-Hans，用 String(localized:)).
#
#   scripts/check-strings.sh [--root DIR] [--update] [-q]
#
# Scans every Sources/**/*.swift file that carries the marker line
#   // l10n: zh-Hans (scripts/check-strings.sh)
# and checks, against Resources/Localizable.xcstrings:
#   1. the catalog is valid JSON with "sourceLanguage": "zh-Hans";
#   2. every localized literal is a key in the catalog: `String(localized: "…")`, and the first
#      argument of SwiftUI's LocalizedStringKey initializers (Text, Button, Toggle, Label, Picker,
#      LabeledContent, Section, Menu, DisclosureGroup, ProgressView, alert, confirmationDialog,
#      help, navigationTitle). The app's own views take already-localized Strings, so a literal
#      passed to one of them (even as `title:`) is bare;
#   3. no literal containing CJK text outside those (a bare "中文" in a marked file is an
#      error; `Text(verbatim:)` is for data, not for text). `// l10n-ignore` at the end of a line
#      exempts that line;
#   4. no stale key (in the catalog, used nowhere), unless its entry says
#      "extractionState": "manual";
#   5. titlebar short labels stay short (redesign §3): `titlebarLabel("…")` at most 10 and
#      `noticeLabel("…")` at most 8 units, where a CJK character, a run of Latin letters/digits
#      and an interpolation each count as one; spaces and punctuation are free.
# Interpolations `\(…)` become `%@` in the key; catalog keys compare with %@ / %lld / %ld / %d /
# %lf / %f (and positional %1$@) treated alike, so a catalog edited in Xcode still matches.
# The Chinese source keys are stable identifiers. compile-localizations.py validates both
# translations and uses compiler extraction to emit typed .strings tables for the app.
#
# --update rewrites the catalog: adds missing keys, drops stale non-manual ones, sorts.
# Exit: 0 ok, 1 problems found, 2 usage error.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
update=0; quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { echo "usage: $0 [--root DIR] [--update] [-q]" >&2; exit 2; }; root="$2"; shift 2 ;;
    --update) update=1; shift ;;
    -q) quiet=1; shift ;;
    *) echo "usage: $0 [--root DIR] [--update] [-q]" >&2; exit 2 ;;
  esac
done
[ -d "$root/Sources" ] || { echo "check-strings: no Sources/ under $root" >&2; exit 2; }

# shellcheck disable=SC2016  # the quoted text is Python, not shell
exec "${TALKTALK_DEV_PYTHON:-/usr/bin/python3}" -I -B -c '
import json, os, re, sys

root, update, quiet = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"
MARKER = "// l10n: zh-Hans (scripts/check-strings.sh)"
CATALOG = os.path.join(root, "Resources", "Localizable.xcstrings")
SHORT_LIMITS = {"titlebarLabel": 10, "noticeLabel": 8}
KEY_CALLEES = {"Text", "Button", "Toggle", "Label", "Picker", "LabeledContent", "Section", "Menu", "DisclosureGroup", "ProgressView",
               "alert", "confirmationDialog", "help", "navigationTitle"} | set(SHORT_LIMITS)
CJK_CHAR = re.compile("[㐀-鿿豈-﫿]")
LATIN_RUN = re.compile("[A-Za-z0-9]+")

def short_units(k):
    k = SPEC.sub("X", k)
    return len(CJK_CHAR.findall(k)) + len(LATIN_RUN.findall(CJK_CHAR.sub(" ", k)))
CJK = re.compile("[　-〿㐀-鿿豈-﫿＀-￯]")
SPEC = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|d|lf|f)")

problems = []

def norm(k):
    return SPEC.sub("%@", k)

def scan(path, text, line=1, ignore_lines=None):
    """Returns [(line, literal_key, localized, has_cjk, ignored, callee)]. Code inside an interpolation
    is scanned the same way (a zh literal nested in a localized one is checked on its own)."""
    i, n = 0, len(text)
    stack = []          # callee name per open paren ("" when not a call)
    last_ident = ""     # identifier right before the current position
    prev = ""           # previous significant char / token kind
    label = None        # label just before ":" inside the current call
    if ignore_lines is None:
        ignore_lines = set(idx + 1 for idx, l in enumerate(text.split("\n")) if l.rstrip().endswith("// l10n-ignore"))
    out = []
    def read_literal(i, line, segs=None):
        # at opening quote; returns (end_index, key, cjk, line, multi). `segs` collects the
        # (start, end, line) of the interpolations of this literal.
        if text.startswith("\"\"\"", i):
            j = text.find("\"\"\"", i + 3)
            if j < 0: j = n - 3
            body = text[i + 3:j]
            return j + 3, body, bool(CJK.search(body)), line + body.count("\n"), True
        j = i + 1
        key = []
        cjk = False
        while j < n and text[j] != "\"":
            c = text[j]
            if c == "\n":
                break
            if c == "\\" and j + 1 < n:
                d = text[j + 1]
                if d == "(":
                    # interpolation: skip to the matching paren, nested strings included
                    depth, k = 1, j + 2
                    while k < n and depth:
                        if text[k] == "\"":
                            k = read_literal(k, line)[0]
                            continue
                        if text[k] == "(": depth += 1
                        elif text[k] == ")": depth -= 1
                        k += 1
                    if segs is not None: segs.append((j + 2, k - 1, line))
                    key.append("%@")
                    j = k
                    continue
                key.append({"n": "\n", "t": "\t", "\"": "\"", "\\": "\\", "0": "\0"}.get(d, d))
                j += 2
                continue
            if CJK.match(c): cjk = True
            key.append(c)
            j += 1
        return j + 1, "".join(key), cjk, line, False
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1; i += 1; continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            line += text.count("\n", i, j)
            i = j
            continue
        if c == "\"":
            start_line = line
            segs = []
            j, key, cjk, line, multi = read_literal(i, line, segs)
            callee = stack[-1] if stack else ""
            localized = False
            if callee == "String" and label in {"localized", "appLocalized"}:
                localized = True
            elif callee in KEY_CALLEES and prev == "(":
                localized = True
            if multi:
                localized = False
            out.append((start_line, key, localized, cjk, start_line in ignore_lines, callee if localized else ""))
            for a, b, l0 in segs:
                out.extend(scan(path, text[a:b], l0, ignore_lines))
            i = j
            prev = "lit"; last_ident = ""
            continue
        if c.isalpha() or c == "_":
            j = i
            while j < n and (text[j].isalnum() or text[j] == "_"): j += 1
            last_ident = text[i:j]
            prev = "ident"
            i = j
            continue
        if c == "(":
            stack.append(last_ident if prev == "ident" else "")
            prev = "("; label = None; last_ident = ""
            i += 1; continue
        if c == ")":
            if stack: stack.pop()
            prev = ")"; label = None; last_ident = ""
            i += 1; continue
        if c == ":":
            label = last_ident if prev == "ident" else None
            prev = ":"; last_ident = ""
            i += 1; continue
        if c == ",":
            prev = ","; label = None; last_ident = ""
            i += 1; continue
        if c in " \t\r":
            i += 1; continue
        prev = c; last_ident = ""
        i += 1
    return out

used = {}   # normalized key -> (raw key, file:line)
files = 0
for d, _, fs in os.walk(os.path.join(root, "Sources")):
    for f in sorted(fs):
        if not f.endswith(".swift"): continue
        p = os.path.join(d, f)
        with open(p, encoding="utf-8") as h: text = h.read()
        if MARKER not in text: continue
        files += 1
        rel = os.path.relpath(p, root)
        for line, key, localized, cjk, ignored, callee in scan(p, text):
            if localized and key:
                used.setdefault(norm(key), (key, "%s:%d" % (rel, line)))
                limit = SHORT_LIMITS.get(callee)
                if limit is not None and short_units(key) > limit:
                    problems.append("%s:%d: %s label longer than %d characters (put the sentence in the detail): \"%s\"" % (rel, line, callee, limit, key))
            elif cjk and not ignored:
                problems.append("%s:%d: bare zh-Hans literal (use String(localized:) or a LocalizedStringKey view): \"%s\"" % (rel, line, key))

catalog = {"sourceLanguage": "zh-Hans", "strings": {}, "version": "1.0"}
if os.path.exists(CATALOG):
    try:
        with open(CATALOG, encoding="utf-8") as h: catalog = json.load(h)
    except ValueError as e:
        print("check-strings: %s is not valid JSON: %s" % (CATALOG, e), file=sys.stderr); sys.exit(1)
elif not update:
    problems.append("missing catalog %s (run scripts/check-strings.sh --update)" % os.path.relpath(CATALOG, root))
if catalog.get("sourceLanguage") != "zh-Hans":
    problems.append("catalog sourceLanguage is %r, not \"zh-Hans\"" % catalog.get("sourceLanguage"))
strings = catalog.get("strings") or {}
have = {norm(k): k for k in strings}
missing = sorted(k for k in used if k not in have)
stale = sorted(k for k, raw in have.items() if k not in used and (strings[raw] or {}).get("extractionState") != "manual")

if update:
    for k in missing:
        strings[used[k][0]] = {}
    for k in stale:
        del strings[have[k]]
    catalog["strings"] = {k: strings[k] for k in sorted(strings)}
    catalog["sourceLanguage"] = "zh-Hans"
    catalog.setdefault("version", "1.0")
    os.makedirs(os.path.dirname(CATALOG), exist_ok=True)
    with open(CATALOG, "w", encoding="utf-8") as h:
        json.dump(catalog, h, ensure_ascii=False, indent=2, sort_keys=False)
        h.write("\n")
    if not quiet: print("check-strings: catalog updated (+%d, -%d, %d keys)" % (len(missing), len(stale), len(catalog["strings"])))
    missing, stale = [], []
    problems = [p for p in problems if not p.startswith("missing catalog") and "sourceLanguage" not in p]

for k in missing:
    raw, where = used[k]
    problems.append("%s: key not in the catalog: \"%s\"" % (where, raw))
for k in stale:
    problems.append("stale catalog key (used nowhere): \"%s\"" % have[k])

if problems:
    for p in problems: print("check-strings: " + p, file=sys.stderr)
    print("check-strings: %d problem(s); scripts/check-strings.sh --update adds/removes keys" % len(problems), file=sys.stderr)
    sys.exit(1)
if not quiet:
    print("check-strings: ok (%d files, %d keys)" % (files, len(used)))
' "$root" "$update" "$quiet"
