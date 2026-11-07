#!/bin/bash
# build-app.sh [release|dev]: build TalkTalk.app by default, or an explicit development bundle.
# Assembles in a staging dir, signs inside-out (ad-hoc + fixed designated requirement so TCC
# grants survive rebuilds), runs smoke-test.sh, and only then replaces build/<App>.app.
# The dev build alone is compiled with -DTALKTALK_DEV (--bench store-key and other dev hooks).
# Must run outside the Claude Code sandbox (SwiftPM writes through the per-user temp dir).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
root="$(cd "$here/.." && pwd)"
flavor="${1:-release}"

case "$flavor" in
  dev) app_name="TalkTalk-Dev"; bundle_id="com.aaajiao.talktalk.dev"; display="TalkTalk Dev"; defines=(-Xswiftc -DTALKTALK_DEV) ;;
  release) app_name="TalkTalk"; bundle_id="com.aaajiao.talktalk"; display="TalkTalk"; defines=() ;;
  *) tt_die "usage: build-app.sh [dev|release]" ;;
esac

# Dev and release share generated source and driver output. Keep one project-wide lock
# through reservation, compilation, signing and the final swap; no existing build-slot lock
# is acquired here. The private second argument is used only by this locked re-execution.
if [ "${2:-}" != "--package-lock-held" ]; then
  [ $# -le 1 ] || tt_die "usage: build-app.sh [dev|release]"
  /bin/mkdir -p "$root/build"
  exec /usr/bin/lockf -k "$root/build/.package.lock" "$here/build-app.sh" "$flavor" --package-lock-held
fi
[ $# -eq 2 ] || tt_die "usage: build-app.sh [dev|release]"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"   # SwiftPM + CLT (§2.2)
scratch="$root/.build/$flavor"
# Preflight happens before changing the number: unrelated generated-pin drift must fail,
# not be silently repaired by the build. A reserved number is never rolled back on failure.
"$here/setup-dev-python.sh" --check
export TALKTALK_DEV_PYTHON="$root/.venv/bin/python3"
export PATH="$root/.venv/bin:$PATH"
"$TALKTALK_DEV_PYTHON" -I -B "$here/reserve-app-build.py"
# shellcheck source=lib/versions.sh
. "$here/lib/versions.sh"
version="$TT_APP_VERSION"
build_number="$TT_APP_BUILD"

tt_log "swift build ($flavor, $version ($build_number))"
(cd "$root" && swift build -c release --scratch-path "$scratch" ${defines[@]+"${defines[@]}"} --product TalkTalk) >&2
bin="$scratch/release/TalkTalk"
[ -x "$bin" ] || tt_die "build produced no binary at $bin"
binary_version="$("$bin" --version)"
case "$binary_version" in
  "TalkTalk $version ($build_number) ("*) ;;
  *) tt_die "compiled binary version does not match reserved $version ($build_number): $binary_version" ;;
esac

out_dir="$root/build"
stage="$out_dir/.staging-$flavor"
app="$stage/$app_name.app"
/bin/rm -rf "$stage"
/bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/engine" "$app/Contents/Resources/installer/scripts/lib"
/bin/cp "$bin" "$app/Contents/MacOS/TalkTalk"

# Engine: source and lock files only (no tests, no caches); the bundle is never modified at runtime.
(cd "$root/engine" && /usr/bin/find talktalk_engine.py smoke_engine.py talktalk_engine requirements-engine.lock requirements-build.lock \
    -name __pycache__ -prune -o -type f ! -name '*.pyc' -print 2>/dev/null) | while IFS= read -r f; do
  /bin/mkdir -p "$app/Contents/Resources/engine/$(/usr/bin/dirname "$f")"
  /bin/cp "$root/engine/$f" "$app/Contents/Resources/engine/$f"
done
/bin/cp "$root/scripts/install-engine.sh" "$app/Contents/Resources/installer/scripts/"
/bin/cp "$root/scripts/lib/common.sh" "$root/scripts/lib/versions.sh" "$root/scripts/lib/models.sh" "$app/Contents/Resources/installer/scripts/lib/"
# m0-swift: PolicyProfile and prompts (ResourceLocator looks in Contents/Resources first); the T4
# bench corpus only in the dev build.
/bin/cp "$root/Resources/PolicyProfile.default.json" "$root/Resources/uninstall.sh" "$app/Contents/Resources/"
# Keep the standalone recovery guide and license texts with downloaded app bundles.
/bin/cp "$root/docs/maintenance.md" "$app/Contents/Resources/README.md"
/bin/cp "$root/LICENSE" "$app/Contents/Resources/LICENSE.txt"
/bin/mkdir -p "$app/Contents/Resources/Licenses"
/bin/cp "$root/Driver/third_party/libASPL/LICENSE.apple2012" "$root/Driver/third_party/libASPL/LICENSE.apple2020" "$app/Contents/Resources/Licenses/"
# Finder metadata/resource forks on an imported icon cannot be sealed by codesign.
/bin/cp -X "$root/Resources/TalkTalk.icns" "$app/Contents/Resources/"
/bin/chmod +x "$app/Contents/Resources/uninstall.sh"
/bin/cp -R "$root/Resources/prompts" "$app/Contents/Resources/"
if [ "$flavor" = dev ]; then /bin/cp -R "$root/Resources/bench" "$app/Contents/Resources/"; fi

# m2 driver (§8.4 step 2): the signed TalkTalkAudio.driver with its manifest, the installer script
# and its pins, and the gate probe (a bare Mach-O: the HAL sees no bundle id, so the Feed's gate
# must refuse it). DriverInstaller stages and checks the driver from here; the bundle is never
# modified at runtime. build-driver.sh needs no root and installs nothing.
tt_log "build-driver (ad-hoc)"
"$here/build-driver.sh" --out "$root/build/driver" >&2
drv="$app/Contents/Resources/driver"
/bin/mkdir -p "$drv"
/usr/bin/ditto "$root/build/driver/TalkTalkAudio.driver" "$drv/TalkTalkAudio.driver"
/bin/cp "$root/build/driver/driver-manifest.json" "$root/scripts/driver/install-driver.sh" "$root/scripts/lib/versions.sh" "$drv/"
/usr/bin/xcrun clang -std=c17 -O2 -Wall -Wextra -Werror -arch arm64 -arch x86_64 -mmacosx-version-min=26.0 \
  "$root/tools/feedprobe/feedprobe.c" -framework CoreAudio -framework CoreFoundation -o "$drv/feedprobe" >&2
/usr/bin/codesign --force -s - --identifier "com.aaajiao.talktalk.feedprobe-bare" "$drv/feedprobe" >&2
# Third-party notices (libASPL ships inside the driver, MIT: the notice travels with the binary).
/bin/cp "$root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/"

/bin/cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>$display</string>
  <key>CFBundleDisplayName</key><string>$display</string>
  <key>CFBundleExecutable</key><string>TalkTalk</string>
  <key>CFBundleIconFile</key><string>TalkTalk.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>TalkTalk uses your microphone for original speech and press-to-translate during meeting interpretation, and for recordings you start.</string>
  <key>NSAudioCaptureUsageDescription</key><string>TalkTalk captures sound from the app you select to show live subtitles for meetings or videos.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>TalkTalk uses on-device speech recognition for live subtitles.</string>
</dict>
</plist>
EOF

# Ad-hoc + fixed DR (cicada build.sh): the DR names only the identifier, so TCC keeps its grants
# across rebuilds. Known cost (§2.2): any local program ad-hoc signed with this identifier inherits them.
/usr/bin/codesign --force -s - --identifier "$bundle_id" \
  --requirements "=designated => identifier \"$bundle_id\"" "$app" >&2
/usr/bin/codesign --verify --strict "$app" >&2

"$here/smoke-test.sh" "$app" "$bundle_id" "$flavor"

/bin/mkdir -p "$out_dir"
if [ -e "$out_dir/$app_name.app" ]; then
  tt_assert_safe_dir "$out_dir/$app_name.app"
  /bin/rm -rf "$out_dir/$app_name.app"
fi
/bin/mv "$app" "$out_dir/$app_name.app"
/bin/rm -rf "$stage"
tt_log "built $out_dir/$app_name.app ($bundle_id, $version ($build_number))"
