#!/bin/bash
# shellcheck disable=SC2015  # ok/no always return 0, so "A && ok || no" is a safe if-then-else
# check-strings.sh against planted fixtures: a clean tree passes; a missing key, a bare zh-Hans
# literal (also Text(verbatim:) and a multi-line literal), an over-long titlebar label, a stale
# key, a wrong sourceLanguage, invalid JSON and a missing catalog fail; interpolations match
# %@ / %lld keys; comments, unmarked files and `// l10n-ignore` lines are not checked; manual
# keys may be unused; --update adds and drops keys. Run: scripts/tests/test-check-strings.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cs="$here/../check-strings.sh"

work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tt-strings-test.XXXXXX")"
trap '/bin/rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; /usr/bin/sed 's/^/     | /' "$work/out"; }

# fixture <name>: a tree with one marked file and a matching catalog; prints its root.
fixture() {
  local r="$work/$1"
  /bin/mkdir -p "$r/Sources/App" "$r/Resources"
  cat > "$r/Sources/App/View.swift" <<'EOF'
// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
/// 文档注释里的中文不检查
struct V: View {
    let n: Int
    var body: some View {
        VStack {
            Text("你好")
            Button("继续") {}
            Toggle("热麦", isOn: .constant(true))
            Label("说明文字", systemImage: "info.circle")
            LabeledContent("麦克风") { Text("只在按键时用") }
            Menu("允许…") {}
            Text(verbatim: "en-US")
            Text("已跳过 \(n) 段")
            Picker("", selection: .constant(1)) { Text("A").tag(1) }
        }
        .help("帮助")
    }
    var s: String { String(localized: "原声已关闭：\(n > 1 ? String(localized: "多") : String(localized: "少"))") }
    var t: String { String(localized: "带\"引号\"的文字") }
    var log: String { "pt.close" }
    /* 块注释里的中文 */
    var tag: String { "内部标签" } // l10n-ignore
}
EOF
  cat > "$r/Sources/App/Other.swift" <<'EOF'
// not marked: never checked
let x = "未标记的文件"
EOF
  cat > "$r/Resources/Localizable.xcstrings" <<'EOF'
{
  "sourceLanguage": "zh-Hans",
  "strings": {
    "你好": {},
    "继续": {},
    "热麦": {},
    "说明文字": {},
    "麦克风": {},
    "只在按键时用": {},
    "允许…": {},
    "已跳过 %lld 段": {},
    "A": {},
    "帮助": {},
    "原声已关闭：%@": {},
    "多": {},
    "少": {},
    "带\"引号\"的文字": {},
    "手动保留": { "extractionState": "manual" }
  },
  "version": "1.0"
}
EOF
  printf '%s' "$r"
}

run() {  # run <root> [args...] → rc in $rc, output in $work/out
  local r="$1"; shift
  rc=0
  "$cs" --root "$r" "$@" > "$work/out" 2>&1 || rc=$?
}

R="$(fixture clean)"
run "$R"
[ "$rc" = 0 ] && /usr/bin/grep -q 'ok (1 files, 14 keys)' "$work/out" && ok "clean tree passes (14 keys, nested String(localized:) in an interpolation, %lld matches \\(n), manual key kept)" || no "clean tree (rc=$rc)"

R="$(fixture live)"
/usr/bin/sed -i '' 's/String(localized:/String(appLocalized:/g' "$R/Sources/App/View.swift"
run "$R"
[ "$rc" = 0 ] && /usr/bin/grep -q 'ok (1 files, 14 keys)' "$work/out" && ok "live appLocalized initializer is extracted" || no "appLocalized (rc=$rc)"

R="$(fixture missing)"
/usr/bin/sed -i '' '/"继续": {},/d' "$R/Resources/Localizable.xcstrings"
run "$R"
[ "$rc" = 1 ] && /usr/bin/grep -q 'key not in the catalog: "继续"' "$work/out" && ok "missing key fails" || no "missing key (rc=$rc)"

R="$(fixture bare)"
/usr/bin/sed -i '' 's|var log: String { "pt.close" }|var log: String { "裸的中文" }|' "$R/Sources/App/View.swift"
run "$R"
[ "$rc" = 1 ] && /usr/bin/grep -q 'View.swift:22: bare zh-Hans literal.*"裸的中文"' "$work/out" && ok "bare zh literal fails with file:line" || no "bare literal (rc=$rc)"

R="$(fixture nested)"
/usr/bin/sed -i '' 's|String(localized: "多")|"多"|' "$R/Sources/App/View.swift"
run "$R"
[ "$rc" = 1 ] && /usr/bin/grep -q 'View.swift:20: bare zh-Hans literal.*"多"' "$work/out" \
  && ok "bare zh literal inside a localized literal's interpolation fails" || no "nested bare (rc=$rc)"

R="$(fixture verbatim)"
/usr/bin/sed -i '' 's|Text(verbatim: "en-US")|Text(verbatim: "中文")|' "$R/Sources/App/View.swift"
run "$R"
[ "$rc" = 1 ] && /usr/bin/grep -q 'bare zh-Hans literal.*"中文"' "$work/out" && ok "Text(verbatim:) with zh text fails" || no "verbatim (rc=$rc)"

R="$(fixture second)"
/usr/bin/sed -i '' 's|Toggle("热麦", isOn: .constant(true))|Toggle(isOn: .constant(true)) { Text("热麦") }; Foo(1, "第二个参数"); StepTitle(symbol: "x", title: "带标签的参数")|' "$R/Sources/App/View.swift"
run "$R"
[ "$rc" = 1 ] && /usr/bin/grep -q 'bare zh-Hans literal.*"第二个参数"' "$work/out" \
  && /usr/bin/grep -q 'bare zh-Hans literal.*"带标签的参数"' "$work/out" \
  && ! /usr/bin/grep -q '"热麦"' "$work/out" \
  && ok "unknown callee, later argument or labeled argument to an app view (StepTitle) is bare; trailing-closure Text is a key" || no "second arg (rc=$rc)"

R="$(fixture multiline)"
printf '%s\n' 'let m = """' '多行文字' '"""' >> "$R/Sources/App/View.swift"
run "$R"
[ "$rc" = 1 ] && /usr/bin/grep -q 'bare zh-Hans literal' "$work/out" && ok "multi-line zh literal fails" || no "multi-line (rc=$rc)"

R="$(fixture short)"
printf '%s\n' 'let a = titlebarLabel("未接入 Phone")' 'let b = titlebarLabel("正在重新连接电话请稍候片刻")' \
  'let c = noticeLabel("已恢复 TalkTalk Mic")' 'let d = noticeLabel("系统默认输入已经还原好了")' >> "$R/Sources/App/View.swift"
/usr/bin/sed -i '' 's|"A": {},|"A": {},\n    "未接入 Phone": {},\n    "正在重新连接电话请稍候片刻": {},\n    "已恢复 TalkTalk Mic": {},\n    "系统默认输入已经还原好了": {},|' "$R/Resources/Localizable.xcstrings"
run "$R"
[ "$rc" = 1 ] && /usr/bin/grep -q 'titlebarLabel label longer than 10 characters.*"正在重新连接电话请稍候片刻"' "$work/out" \
  && /usr/bin/grep -q 'noticeLabel label longer than 8 characters.*"系统默认输入已经还原好了"' "$work/out" \
  && ! /usr/bin/grep -q '"未接入 Phone"\|"已恢复 TalkTalk Mic"' "$work/out" \
  && /usr/bin/grep -q '2 problem(s)' "$work/out" \
  && ok "titlebar labels over 10 and notifications over 8 characters fail; Latin words count once" || no "short labels (rc=$rc)"

R="$(fixture stale)"
/usr/bin/sed -i '' 's|"A": {},|"A": {},\n    "没人用": {},|' "$R/Resources/Localizable.xcstrings"
run "$R"
[ "$rc" = 1 ] && /usr/bin/grep -q 'stale catalog key (used nowhere): "没人用"' "$work/out" \
  && ! /usr/bin/grep -q '手动保留' "$work/out" && ok "stale key fails, manual key does not" || no "stale (rc=$rc)"

R="$(fixture lang)"
/usr/bin/sed -i '' 's|"sourceLanguage": "zh-Hans"|"sourceLanguage": "en"|' "$R/Resources/Localizable.xcstrings"
run "$R"
[ "$rc" = 1 ] && /usr/bin/grep -q 'sourceLanguage is' "$work/out" && ok "sourceLanguage other than zh-Hans fails" || no "sourceLanguage (rc=$rc)"

R="$(fixture json)"
printf '{ "strings": ' > "$R/Resources/Localizable.xcstrings"
run "$R"
[ "$rc" = 1 ] && /usr/bin/grep -q 'not valid JSON' "$work/out" && ok "invalid JSON fails" || no "json (rc=$rc)"

R="$(fixture nocat)"
/bin/rm "$R/Resources/Localizable.xcstrings"
run "$R"
[ "$rc" = 1 ] && /usr/bin/grep -q 'missing catalog' "$work/out" && ok "missing catalog fails" || no "no catalog (rc=$rc)"

R="$(fixture update)"
/usr/bin/sed -i '' -e '/"继续": {},/d' -e 's|"A": {},|"A": {},\n    "没人用": {},|' "$R/Resources/Localizable.xcstrings"
run "$R" --update -q
rc1=$rc
run "$R"
[ "$rc1" = 0 ] && [ "$rc" = 0 ] && /usr/bin/grep -q '"继续"' "$R/Resources/Localizable.xcstrings" \
  && ! /usr/bin/grep -q '没人用' "$R/Resources/Localizable.xcstrings" \
  && /usr/bin/grep -q '手动保留' "$R/Resources/Localizable.xcstrings" \
  && /usr/bin/grep -q '"sourceLanguage": "zh-Hans"' "$R/Resources/Localizable.xcstrings" \
  && ok "--update adds missing, drops stale, keeps manual; then passes" || no "update (rc1=$rc1 rc=$rc)"

R="$(fixture create)"
/bin/rm "$R/Resources/Localizable.xcstrings"
run "$R" --update -q
rc1=$rc
run "$R"
[ "$rc1" = 0 ] && [ "$rc" = 0 ] && ok "--update creates a missing catalog" || no "create (rc1=$rc1 rc=$rc)"

R="$(fixture quiet)"
run "$R" -q
[ "$rc" = 0 ] && [ ! -s "$work/out" ] && ok "-q prints nothing when ok" || no "quiet (rc=$rc)"

for args in "--bogus" "--root"; do
  rc=0
  # shellcheck disable=SC2086
  "$cs" $args > "$work/out" 2>&1 || rc=$?
  [ "$rc" = 2 ] && ok "usage error exits 2: $args" || no "usage '$args' (rc=$rc)"
done
rc=0; "$cs" --root "$work/nowhere" > "$work/out" 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "root without Sources/ exits 2" || no "no Sources (rc=$rc)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
