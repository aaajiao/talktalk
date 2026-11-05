#!/bin/bash
# Build the M0-T8 driver test clients into build/bench-driver/ (no root, no install).
#
#   ttdrv               bare binary: no bundle id -> must be refused by the Feed gate
#   TTDriverBench.app   com.aaajiao.talktalk.dev   -> passes the gate; launch with `open` for
#                       anything that reads TalkTalk Mic / Test Mic (TCC microphone prompt is
#                       then attributed to TTDriverBench, not to the terminal)
#   FeedProbe.app       com.aaajiao.talktalk.feedprobe -> must be refused (§8.4 门禁测试)
#   plugin_harness      loads the driver in-process with a fake HAL host (no coreaudiod)
#
# Apps are ad-hoc signed with a designated requirement on the identifier only (the same form
# the real app uses, §2.2), so a TCC grant survives rebuilds.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="$ROOT/tools/bench/driver"
OUT="$ROOT/build/bench-driver"
mkdir -p "$OUT"

CXX=(clang++ -std=c++17 -O2 -g -Wall -Wextra -Wno-unused-parameter -arch arm64 -mmacosx-version-min=26.0)

"${CXX[@]}" -o "$OUT/ttdrv" "$SRC/ttdrv.cpp" -framework CoreAudio -framework CoreFoundation
"${CXX[@]}" -o "$OUT/plugin_harness" "$SRC/plugin_harness.cpp" -framework CoreAudio -framework CoreFoundation
codesign --force -s - --identifier ttdrv "$OUT/ttdrv"
codesign --force -s - --identifier plugin_harness "$OUT/plugin_harness"

make_app() {
    local name="$1" id="$2"
    local app="$OUT/$name.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "$OUT/ttdrv" "$app/Contents/MacOS/ttdrv"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>ttdrv</string>
	<key>CFBundleIdentifier</key><string>$id</string>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
	<key>NSMicrophoneUsageDescription</key><string>M0-T8 driver test: reads TalkTalk Mic and TalkTalk Test Mic to check the loopback.</string>
</dict>
</plist>
PLIST
    codesign --force -s - --identifier "$id" \
        --requirements "=designated => identifier \"$id\"" "$app"
}
make_app TTDriverBench com.aaajiao.talktalk.dev
make_app FeedProbe com.aaajiao.talktalk.feedprobe

echo "built into $OUT: ttdrv plugin_harness TTDriverBench.app FeedProbe.app"
