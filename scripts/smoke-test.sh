#!/bin/bash
# smoke-test.sh <app> <bundle id> <dev|release>: checks a freshly assembled bundle before
# build-app.sh swaps it in. Does not touch TCC, the Keychain, the network or audio devices.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
app="$1"; id="$2"; flavor="$3"
exe="$app/Contents/MacOS/TalkTalk"
# shellcheck source=lib/updates.sh
. "$here/lib/updates.sh"

[ -x "$exe" ] || tt_die "smoke: no executable"
# Installed bundles can be checked from a newer checkout: validate receipt shape here;
# build embedding and publication separately compare it with the owning source tree.
"${TALKTALK_DEV_PYTHON:-/usr/bin/python3}" -I -B "$here/source-provenance.py" inspect --app "$app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = "$id" ] || tt_die "smoke: bundle id"
req="$(/usr/bin/codesign -d -r- "$app" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
[ "$req" = "identifier \"$id\"" ] || tt_die "smoke: designated requirement is '$req'"
# Sparkle and its helpers must survive copying with their versioned layout intact.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
[ -L "$sparkle/Versions/Current" ] && [ -L "$sparkle/Sparkle" ] || tt_die "smoke: Sparkle framework symlinks missing"
for helper in Autoupdate Updater.app/Contents/MacOS/Updater XPCServices/Installer.xpc/Contents/MacOS/Installer XPCServices/Downloader.xpc/Contents/MacOS/Downloader; do
  [ -x "$sparkle/Versions/B/$helper" ] || tt_die "smoke: Sparkle helper $helper missing"
done
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$sparkle/Resources/Info.plist")" = "$TT_SPARKLE_VERSION" ] || tt_die "smoke: Sparkle version"
/usr/bin/codesign --verify --deep --strict "$app" 2>/dev/null || tt_die "smoke: nested bundle signing failed"
[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app/Contents/Info.plist")" = "$TT_UPDATE_FEED_URL" ] || tt_die "smoke: update feed URL"
[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" = "$TT_UPDATE_PUBLIC_KEY" ] || tt_die "smoke: updater public key"
for flag in SUEnableAutomaticChecks SUAutomaticallyUpdate SUAllowsAutomaticUpdates SUSendProfileInfo; do
  [ "$(/usr/libexec/PlistBuddy -c "Print :$flag" "$app/Contents/Info.plist")" = false ] || tt_die "smoke: $flag must be false"
done
for flag in SUVerifyUpdateBeforeExtraction SURequireSignedFeed; do
  [ "$(/usr/libexec/PlistBuddy -c "Print :$flag" "$app/Contents/Info.plist")" = true ] || tt_die "smoke: $flag must be true"
done
[ "$(/usr/libexec/PlistBuddy -c 'Print :SUSignedFeedFailureExpirationInterval' "$app/Contents/Info.plist")" = 0 ] || tt_die "smoke: signed-feed failures must never expire"
version="$("$exe" --version)"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
case "$version" in
  "TalkTalk $app_version ($app_build) ("*) ;;
  *) tt_die "smoke: --version '$version' disagrees with Info.plist $app_version ($app_build)" ;;
esac
# Exercise Foundation lookup and numeric interpolation in both shipped languages. These
# subprocesses use a volatile preference override, with no audio or saved setting changes.
for language in en zh-Hans; do
  [ -f "$app/Contents/Resources/$language.lproj/Localizable.strings" ] || tt_die "smoke: $language language pack missing"
  "$exe" --check-localization "$language" || tt_die "smoke: $language localization failed"
done
# The dev hooks (store-key) must be compiled into dev and absent from release.
out="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/tt-smoke.XXXXXX")"
trap '/bin/rm -f "$out"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$flavor" = "release" ]; then
  case "$version" in *"dev hooks: none"*) ;; *) tt_die "smoke: release build has dev hooks ($version)" ;; esac
  if "$exe" --bench store-key --out "$out" 2>/dev/null; then tt_die "smoke: release build accepted --bench store-key"; fi
else
  case "$version" in *"dev hooks: store-key"*) ;; *) tt_die "smoke: dev build lacks --bench store-key ($version)" ;; esac
fi
/bin/rm -f "$out"
for f in talktalk_engine.py requirements-engine.lock requirements-build.lock; do
  [ -f "$app/Contents/Resources/engine/$f" ] || tt_die "smoke: engine/$f missing from bundle"
done
for f in install-engine.sh lib/common.sh lib/versions.sh lib/models.sh; do
  [ -f "$app/Contents/Resources/installer/scripts/$f" ] || tt_die "smoke: installer/scripts/$f missing"
done
[ -x "$app/Contents/Resources/uninstall.sh" ] || tt_die "smoke: uninstall.sh missing"
[ -f "$app/Contents/Resources/README.md" ] || tt_die "smoke: manual uninstall guide missing"
[ -f "$app/Contents/Resources/LICENSE.txt" ] || tt_die "smoke: project MIT license missing"
for notice in LICENSE.apple2012 LICENSE.apple2020 Sparkle-LICENSE.txt; do
  [ -f "$app/Contents/Resources/Licenses/$notice" ] || tt_die "smoke: $notice missing"
done
# m2 driver: what DriverInstaller and the self-test need (§8.4), and the bundled driver must match
# its own manifest's version and pass codesign --strict as copied.
drv="$app/Contents/Resources/driver"
for f in TalkTalkAudio.driver/Contents/Info.plist driver-manifest.json install-driver.sh versions.sh; do
  [ -e "$drv/$f" ] || tt_die "smoke: driver/$f missing"
done
[ -x "$drv/feedprobe" ] || tt_die "smoke: driver/feedprobe missing"
manifest_version="$(/usr/bin/plutil -extract version raw -o - "$drv/driver-manifest.json")"
plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$drv/TalkTalkAudio.driver/Contents/Info.plist")"
[ "$manifest_version" = "$plist_version" ] || tt_die "smoke: driver manifest $manifest_version, Info.plist $plist_version"
/usr/bin/codesign --verify --strict "$drv/TalkTalkAudio.driver" 2>/dev/null || tt_die "smoke: bundled driver fails codesign --verify --strict"
/usr/bin/grep -q '^## libASPL' "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" || tt_die "smoke: THIRD_PARTY_NOTICES.md lacks the libASPL section"
/usr/bin/grep -q '^## Sparkle' "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" || tt_die "smoke: THIRD_PARTY_NOTICES.md lacks the Sparkle section"
tt_log "smoke: ok ($flavor)"
