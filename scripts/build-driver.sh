#!/bin/bash
# Build TalkTalkAudio.driver (ARCHITECTURE.md, "平台与模块").
#
# CLT clang++ only (no CMake, no Xcode project): compiles vendored libASPL v3.1.2 and
# Driver/Sources/*.cpp as a universal (arm64 + x86_64) bundle, assembles the .driver,
# signs it, and writes driver-manifest.json (sha256 of every file) next to it.
#
# Usage:
#   scripts/build-driver.sh [--sign adhoc|adhoc-runtime|identity:<name or SHA-1>|none]
#                           [--mic-mode remove|hidden|always]
#                           [--mic-in-use io|client]
#                           [--out DIR] [--trace] [--debug]
#
# Signing ladder (§8.5): level 0 = adhoc (and variants: adhoc-runtime, provenance handling in
# install-driver.sh), level 1 = a self-signed local code-signing identity, level 2 = a free
# Apple ID "Apple Development" identity. Both 1 and 2 use --sign identity:<name>.
#
# Nothing here needs root, and nothing is installed. See scripts/driver/install-driver.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/versions.sh
source "$ROOT/scripts/lib/versions.sh"

SIGN="adhoc"
MIC_MODE="remove"
MIC_IN_USE="io"
OUT="$ROOT/build/driver"
TRACE=0
OPT=(-O2)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign) SIGN="$2"; shift 2 ;;
        --mic-mode) MIC_MODE="$2"; shift 2 ;;
        --mic-in-use) MIC_IN_USE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --trace) TRACE=1; shift ;;
        --debug) OPT=(-O0 -g); shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "build-driver: unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$MIC_MODE" in
    remove) MIC_MODE_NUM=0 ;;
    hidden) MIC_MODE_NUM=1 ;;
    always) MIC_MODE_NUM=2 ;;
    *) echo "build-driver: --mic-mode must be remove|hidden|always" >&2; exit 2 ;;
esac
case "$MIC_IN_USE" in
    io) MIC_IN_USE_NUM=0 ;;
    client) MIC_IN_USE_NUM=1 ;;
    *) echo "build-driver: --mic-in-use must be io|client" >&2; exit 2 ;;
esac

log() { printf 'build-driver: %s\n' "$*"; }

CXX="$(xcrun --find clang++ 2>/dev/null || echo /usr/bin/clang++)"
SDK="$(xcrun --show-sdk-path 2>/dev/null)"
[[ -d "$SDK" ]] || { echo "build-driver: macOS SDK not found (xcrun --show-sdk-path)" >&2; exit 1; }

ASPL="$ROOT/Driver/third_party/libASPL"
OBJ="$OUT/obj"
BUNDLE="$OUT/$TT_DRIVER_BUNDLE_NAME"
STAGE="$OUT/.stage-$$"

rm -rf "$OBJ" "$STAGE"
mkdir -p "$OBJ" "$OUT"
trap 'rm -rf "$STAGE"' EXIT

COMMON_FLAGS=(
    -std=c++17 "${OPT[@]}"
    -arch arm64 -arch x86_64
    -isysroot "$SDK"
    "-mmacosx-version-min=$TT_DRIVER_MIN_MACOS"
    -fPIC -fvisibility=hidden -fvisibility-inlines-hidden
    -Wall -Wextra -Wno-unused-parameter -Wno-invalid-offsetof
    # vendored headers as system headers: their warnings (e.g. -Wreorder-init-list in
    # Stream.hpp with clang 21) are upstream's, not ours, and must not trip -Werror below
    -isystem "$ASPL/include"
)
ASPL_ONLY_FLAGS=(-I "$ASPL/src" -Wno-reorder-init-list)

TT_FLAGS=(
    "-DTT_DRIVER_VERSION_STR=\"$TT_DRIVER_VERSION\""
    "-DTT_MIC_MODE=$MIC_MODE_NUM"
    "-DTT_MIC_IN_USE_BY_CLIENT=$MIC_IN_USE_NUM"
    "-DTT_DRIVER_TRACE=$TRACE"
    -Werror
)

log "clang++: $("$CXX" --version 2>/dev/null | head -1)"
log "SDK: $SDK ($(xcrun --show-sdk-version 2>/dev/null))"
log "version=$TT_DRIVER_VERSION mic-mode=$MIC_MODE mic-in-use=$MIC_IN_USE sign=$SIGN"

objs=()
for src in "$ASPL"/src/*.cpp; do
    o="$OBJ/aspl_$(basename "${src%.cpp}").o"
    "$CXX" "${COMMON_FLAGS[@]}" "${ASPL_ONLY_FLAGS[@]}" -c "$src" -o "$o"
    objs+=("$o")
done
for src in "$ROOT"/Driver/Sources/*.cpp; do
    o="$OBJ/tt_$(basename "${src%.cpp}").o"
    "$CXX" "${COMMON_FLAGS[@]}" "${TT_FLAGS[@]}" -c "$src" -o "$o"
    objs+=("$o")
done

mkdir -p "$STAGE/$TT_DRIVER_BUNDLE_NAME/Contents/MacOS" "$STAGE/$TT_DRIVER_BUNDLE_NAME/Contents/Resources"
BIN="$STAGE/$TT_DRIVER_BUNDLE_NAME/Contents/MacOS/$TT_DRIVER_EXECUTABLE"

"$CXX" -arch arm64 -arch x86_64 -isysroot "$SDK" "-mmacosx-version-min=$TT_DRIVER_MIN_MACOS" \
    -bundle -o "$BIN" "${objs[@]}" \
    -Wl,-exported_symbol,"_$TT_DRIVER_FACTORY_FUNC" \
    -framework CoreAudio -framework CoreFoundation -framework Security \
    -Wl,-dead_strip

# Here-string, not a pipe: `nm | grep -q` can SIGPIPE nm and fail under pipefail.
grep -q "_$TT_DRIVER_FACTORY_FUNC" <<< "$(nm -gU "$BIN")" \
    || { echo "build-driver: factory symbol _$TT_DRIVER_FACTORY_FUNC not exported" >&2; exit 1; }
log "archs: $(lipo -archs "$BIN")"

sed -e "s|@EXECUTABLE@|$TT_DRIVER_EXECUTABLE|g" \
    -e "s|@BUNDLE_ID@|$TT_DRIVER_BUNDLE_ID|g" \
    -e "s|@VERSION@|$TT_DRIVER_VERSION|g" \
    -e "s|@MIN_MACOS@|$TT_DRIVER_MIN_MACOS|g" \
    -e "s|@FACTORY_UUID@|$TT_DRIVER_FACTORY_UUID|g" \
    -e "s|@FACTORY_FUNC@|$TT_DRIVER_FACTORY_FUNC|g" \
    -e "s|@MIC_MODE@|$MIC_MODE|g" \
    "$ROOT/Driver/Info.plist.in" > "$STAGE/$TT_DRIVER_BUNDLE_NAME/Contents/Info.plist"
plutil -lint -s "$STAGE/$TT_DRIVER_BUNDLE_NAME/Contents/Info.plist"
cp "$ASPL/LICENSE" "$STAGE/$TT_DRIVER_BUNDLE_NAME/Contents/Resources/libASPL-LICENSE.txt"

# --- sign (§8.5) ---------------------------------------------------------------------------
SIGN_KIND="$SIGN"
case "$SIGN" in
    none)
        log "not signing (linker ad-hoc signature only)" ;;
    adhoc)
        codesign --force --sign - --identifier "$TT_DRIVER_BUNDLE_ID" --timestamp=none \
            "$STAGE/$TT_DRIVER_BUNDLE_NAME" ;;
    adhoc-runtime)
        codesign --force --sign - --identifier "$TT_DRIVER_BUNDLE_ID" --timestamp=none \
            --options runtime "$STAGE/$TT_DRIVER_BUNDLE_NAME" ;;
    identity:*)
        IDENT="${SIGN#identity:}"
        SIGN_KIND="identity"
        codesign --force --sign "$IDENT" --identifier "$TT_DRIVER_BUNDLE_ID" --timestamp=none \
            "$STAGE/$TT_DRIVER_BUNDLE_NAME" ;;
    *) echo "build-driver: --sign must be adhoc|adhoc-runtime|identity:<name>|none" >&2; exit 2 ;;
esac

if [[ "$SIGN" != none ]]; then
    codesign --verify --strict --verbose=2 "$STAGE/$TT_DRIVER_BUNDLE_NAME" 2>&1 | sed 's/^/build-driver: /'
fi
codesign -dv --verbose=4 "$STAGE/$TT_DRIVER_BUNDLE_NAME" > "$STAGE/codesign-dv.txt" 2>&1 || true

# --- manifest (§8.4 step 2: per-file sha256, checked again by install-driver.sh as root) ----
MANIFEST="$STAGE/driver-manifest.json"
{
    printf '{\n'
    printf '  "bundleName": "%s",\n' "$TT_DRIVER_BUNDLE_NAME"
    printf '  "bundleIdentifier": "%s",\n' "$TT_DRIVER_BUNDLE_ID"
    printf '  "version": "%s",\n' "$TT_DRIVER_VERSION"
    printf '  "micMode": "%s",\n' "$MIC_MODE"
    printf '  "micInUse": "%s",\n' "$MIC_IN_USE"
    printf '  "sign": "%s",\n' "$SIGN_KIND"
    printf '  "libASPL": "%s@%s",\n' "$TT_LIBASPL_VERSION" "$TT_LIBASPL_COMMIT"
    printf '  "files": [\n'
    first=1
    while IFS= read -r -d '' f; do
        rel="${f#"$STAGE/$TT_DRIVER_BUNDLE_NAME/"}"
        sum="$(shasum -a 256 "$f" | awk '{print $1}')"
        size="$(stat -f %z "$f")"
        [[ $first -eq 1 ]] || printf ',\n'
        first=0
        printf '    {"path": "%s", "bytes": %s, "sha256": "%s"}' "$rel" "$size" "$sum"
    done < <(find "$STAGE/$TT_DRIVER_BUNDLE_NAME" -type f -print0 | LC_ALL=C sort -z)
    printf '\n  ]\n}\n'
} > "$MANIFEST"
plutil -convert json -o /dev/null "$MANIFEST" 2>/dev/null \
    || python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MANIFEST"

# --- publish atomically into $OUT ----------------------------------------------------------
rm -rf "$BUNDLE.old"
[[ -e "$BUNDLE" ]] && mv "$BUNDLE" "$BUNDLE.old"
mv "$STAGE/$TT_DRIVER_BUNDLE_NAME" "$BUNDLE"
mv "$MANIFEST" "$OUT/driver-manifest.json"
mv "$STAGE/codesign-dv.txt" "$OUT/codesign-dv.txt"
rm -rf "$BUNDLE.old" "$OBJ"

log "built $BUNDLE"
grep -E '^(Identifier|Format|CodeDirectory|Signature|Authority|TeamIdentifier|Runtime)' "$OUT/codesign-dv.txt" | sed 's/^/build-driver:   /' || true
log "manifest $OUT/driver-manifest.json"
