#!/bin/bash
# Install / uninstall TalkTalkAudio.driver (ARCHITECTURE.md, "平台与模块").
#
#   sudo install-driver.sh [--json] install <staged TalkTalkAudio.driver> [--manifest FILE]
#                                         [--strip-provenance] [--no-restart]
#   sudo install-driver.sh [--json] uninstall [--no-restart]
#   sudo install-driver.sh [--json] restart-audio
#        install-driver.sh [--json] status            (no root needed)
#
# In the app this runs once per action via NSAppleScript "with administrator privileges"
# (§8.4); during M0 you run it with sudo yourself. It only ever touches these exact paths:
#   /Library/Audio/Plug-Ins/HAL/TalkTalkAudio.driver
#   /Library/Audio/Plug-Ins/HAL/.TalkTalkAudio.driver.old
#   /Library/Audio/Plug-Ins/HAL/.TalkTalkAudio.driver.tmp-*
# and refuses anything whose CFBundleIdentifier is not ours, or that is a symlink.
#
# Restarting coreaudiod interrupts all audio on the Mac for ~1-2 s. Order of attempts:
#   1. launchctl kickstart -k system/com.apple.audio.coreaudiod
#   2. SIGTERM to the one PID launchd reports for that job (never kill by name)
# Both failing means "on disk, not loaded": log out or restart.
#
# Output (stdout): human-readable "install-driver: ..." lines plus machine-readable
# "tt-install: key=value" lines. With --json every stdout line is one JSON object instead:
#   {"kind":"msg","msg":"..."}  or  {"kind":"kv","key":"...","value":"..."}
# The last kv line is always key "result": ok | error | on-disk-not-loaded | removed-still-loaded
# | restart-failed. Errors also go to stderr as plain text.
# Exit codes: 0 ok; 1 refused / validation failed (nothing changed, or the previous version is
# still in place); 2 usage; 3 the files were changed but restarting coreaudiod failed
# (log out or restart to load / unload).
# Env for script tests only: TT_HAL_DIR (default /Library/Audio/Plug-Ins/HAL),
# TT_INSTALL_ALLOW_NONROOT=1 (with TT_HAL_DIR, skips the root check).
# TT_INSTALL_TEST_FAIL_AFTER_COPY=1 (tests only: honoured only when not root and
# TT_INSTALL_ALLOW_NONROOT=1): install fails right after copying into the tmp dir.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Pins come from scripts/lib/versions.sh; inside the app bundle that file is copied next to this
# script (Contents/Resources/driver/versions.sh).
if [[ -f "$HERE/versions.sh" ]]; then
    VERSIONS="$HERE/versions.sh"
else
    VERSIONS="$HERE/../lib/versions.sh"
fi
# shellcheck disable=SC1090,SC1091  # path chosen at run time, see scripts/lib/versions.sh
source "$VERSIONS"

HAL_DIR="${TT_HAL_DIR:-/Library/Audio/Plug-Ins/HAL}"
NAME="$TT_DRIVER_BUNDLE_NAME"
TARGET="$HAL_DIR/$NAME"
OLD="$HAL_DIR/.$NAME.old"
TMP_PREFIX="$HAL_DIR/.$NAME.tmp-"
OUR_ID="$TT_DRIVER_BUNDLE_ID"
AUDIO_JOB="system/com.apple.audio.coreaudiod"

JSON=0
if [[ "${1:-}" == "--json" ]]; then
    JSON=1
    shift
fi

json_str() {
    # Minimal JSON string escaping: backslash, quote, and control characters.
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}
say() {
    if [[ $JSON -eq 1 ]]; then
        printf '{"kind":"msg","msg":%s}\n' "$(json_str "$*")"
    else
        printf 'install-driver: %s\n' "$*"
    fi
}
kv() {
    if [[ $JSON -eq 1 ]]; then
        printf '{"kind":"kv","key":%s,"value":%s}\n' "$(json_str "$1")" "$(json_str "$2")"
    else
        printf 'tt-install: %s=%s\n' "$1" "$2"
    fi
}
die() {
    printf 'install-driver: error: %s\n' "$*" >&2
    kv error "$*"
    kv result "error"
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        if [[ "${TT_INSTALL_ALLOW_NONROOT:-0}" == 1 && -n "${TT_HAL_DIR:-}" ]]; then
            return 0
        fi
        die "must run as root (sudo)"
    fi
}

bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

is_ours() {
    [[ -d "$1" && ! -L "$1" && "$(bundle_id "$1")" == "$OUR_ID" ]]
}

xattr_summary() {
    # Distinct extended-attribute names anywhere in the bundle, comma-separated.
    local names
    names="$(xattr -r "$1" 2>/dev/null | sed -E 's/^.*: ([^:]+)$/\1/' | sort -u | paste -sd, - || true)"
    printf '%s' "${names:-none}"
}

coreaudiod_pid() {
    # awk reads all input (no early `exit`): an early exit SIGPIPEs the writer, and under
    # `set -o pipefail` + `set -e` the assignment then kills the script silently (M0-T8 d4).
    launchctl print "$AUDIO_JOB" 2>/dev/null | awk '/^[[:space:]]*pid = / && !f {print $3; f = 1}'
}

driver_host_pid() {
    # The per-driver host process is titled "Core Audio Driver (<bundle name>)" on 27.2.
    # Read-only lookup; we never signal it.
    ps -axo pid=,command= | awk -v n="Core Audio Driver ($NAME)" 'index($0, n) && !f {print $1; f = 1}'
}

cleanup_leftovers() {
    # Idempotency (§8.4): finish or undo an interrupted previous run. Only our bundles.
    if [[ -e "$OLD" ]]; then
        if is_ours "$OLD"; then
            if [[ ! -e "$TARGET" ]]; then
                say "restoring $OLD (previous run was interrupted)"
                mv "$OLD" "$TARGET"
            else
                rm -rf "$OLD"
            fi
        else
            say "leaving $OLD alone: not ours"
        fi
    fi
    local t
    for t in "$TMP_PREFIX"*; do
        [[ -e "$t" ]] || continue
        if is_ours "$t"; then
            rm -rf "$t"
        else
            say "leaving $t alone: not ours"
        fi
    done
}

verify_manifest() {
    local bundle="$1" manifest="$2"
    [[ -f "$manifest" ]] || die "manifest not found: $manifest"
    [[ "$(plutil -extract bundleIdentifier raw -o - "$manifest")" == "$OUR_ID" ]] \
        || die "manifest bundleIdentifier is not $OUR_ID"
    local count i path sum bytes actual_sum actual_bytes
    count="$(plutil -extract files raw -o - "$manifest")"
    [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || die "manifest has no files"
    for ((i = 0; i < count; i++)); do
        path="$(plutil -extract "files.$i.path" raw -o - "$manifest")"
        sum="$(plutil -extract "files.$i.sha256" raw -o - "$manifest")"
        bytes="$(plutil -extract "files.$i.bytes" raw -o - "$manifest")"
        [[ "$path" != *..* && "$path" != /* ]] || die "manifest path not allowed: $path"
        [[ -f "$bundle/$path" && ! -L "$bundle/$path" ]] || die "missing file: $path"
        actual_bytes="$(stat -f %z "$bundle/$path")"
        actual_sum="$(shasum -a 256 "$bundle/$path" | awk '{print $1}')"
        [[ "$actual_bytes" == "$bytes" && "$actual_sum" == "$sum" ]] || die "checksum mismatch: $path"
    done
    local present
    present="$(find "$bundle" -type f | wc -l | tr -d ' ')"
    [[ "$present" == "$count" ]] || die "bundle has $present files, manifest lists $count"
    # -print -quit instead of `| grep -q .`: grep -q exits at the first match, SIGPIPEs find,
    # and with pipefail the condition would read as "no symlinks".
    if [[ -n "$(find "$bundle" -type l -print -quit)" ]]; then
        die "bundle contains symlinks"
    fi
    say "manifest ok ($count files)"
}

restart_audio() {
    local before after method="" err
    before="$(coreaudiod_pid)"
    kv coreaudiod_pid_before "${before:-none}"

    if err="$(launchctl kickstart -k "$AUDIO_JOB" 2>&1)"; then
        method="kickstart"
    else
        kv kickstart_error "$(printf '%s' "$err" | tr '\n' ' ')"
        say "launchctl kickstart failed: $err"
        if [[ -n "$before" ]]; then
            if kill -TERM "$before" 2>/dev/null; then
                method="sigterm-pid"
            else
                kv sigterm_error "kill -TERM $before failed"
            fi
        fi
    fi

    if [[ -z "$method" ]]; then
        kv restart_method "failed"
        say "could not restart coreaudiod; the driver is on disk but not loaded (log out or restart)"
        return 1
    fi

    # launchd respawns coreaudiod (KeepAlive / on demand). Wait for a new PID.
    local i
    for ((i = 0; i < 40; i++)); do
        after="$(coreaudiod_pid)"
        if [[ -n "$after" && "$after" != "$before" ]]; then
            break
        fi
        # Nudge on-demand launch: any HAL client query starts coreaudiod again.
        sleep 0.25
    done
    kv restart_method "$method"
    kv coreaudiod_pid_after "${after:-none}"
    [[ -n "${after:-}" && "$after" != "$before" ]] || say "warning: coreaudiod PID did not change"
}

wait_driver_host() {
    local i pid=""
    for ((i = 0; i < 30; i++)); do
        pid="$(driver_host_pid)"
        [[ -n "$pid" ]] && break
        sleep 0.5
    done
    kv driver_host_pid "${pid:-none}"
    if [[ -n "$pid" ]]; then
        kv driver_host "$(ps -o user=,command= -p "$pid" | sed 's/  */ /g')"
    else
        say "no 'Core Audio Driver ($NAME)' process after 15 s (not loaded, or loaded elsewhere)"
    fi
}

cmd_install() {
    require_root
    local staged="" manifest="" strip_prov=0 restart=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --manifest) manifest="$2"; shift 2 ;;
            --strip-provenance) strip_prov=1; shift ;;
            --no-restart) restart=0; shift ;;
            -*) die "unknown option $1" ;;
            *) staged="$1"; shift ;;
        esac
    done
    [[ -n "$staged" ]] || die "usage: install <staged $NAME>"
    staged="$(cd "$staged" && pwd)"
    [[ -z "$manifest" ]] && manifest="$(dirname "$staged")/driver-manifest.json"

    [[ ! -L "$staged" ]] || die "staged bundle is a symlink"
    is_ours "$staged" || die "staged bundle identifier is not $OUR_ID"
    verify_manifest "$staged" "$manifest"
    codesign --verify --strict "$staged" 2>/dev/null || die "staged bundle fails codesign --verify --strict"

    [[ -d "$HAL_DIR" ]] || die "$HAL_DIR missing"
    [[ ! -L "$TARGET" ]] || die "$TARGET is a symlink; refusing"
    if [[ -e "$TARGET" ]] && ! is_ours "$TARGET"; then
        die "$TARGET exists and is not ours; refusing"
    fi
    cleanup_leftovers

    local tmp="$TMP_PREFIX$$"
    # Any exit before the tmp copy has become $TARGET (a failed check below, set -e, a signal)
    # removes it: a root-owned .tmp-* left behind is otherwise only cleaned by the next run.
    PENDING_TMP="$tmp"
    trap 'if [[ -n "${PENDING_TMP:-}" ]]; then rm -rf "$PENDING_TMP"; fi' EXIT
    ditto "$staged" "$tmp"
    if [[ "${TT_INSTALL_TEST_FAIL_AFTER_COPY:-0}" == 1 && $EUID -ne 0 && "${TT_INSTALL_ALLOW_NONROOT:-0}" == 1 ]]; then
        die "test: failing after the copy (TT_INSTALL_TEST_FAIL_AFTER_COPY)"
    fi
    kv xattrs_after_copy "$(xattr_summary "$tmp")"
    if [[ $EUID -eq 0 ]]; then
        chown -R root:wheel "$tmp"
    fi
    chmod -R go-w "$tmp"
    xattr -dr com.apple.quarantine "$tmp" 2>/dev/null || true
    if [[ $strip_prov -eq 1 ]]; then
        if xattr -dr com.apple.provenance "$tmp" 2>/dev/null; then
            kv strip_provenance "ok"
        else
            kv strip_provenance "failed"
        fi
    fi
    kv xattrs_installed "$(xattr_summary "$tmp")"
    verify_manifest "$tmp" "$manifest"
    codesign --verify --strict "$tmp" 2>/dev/null || die "copied bundle fails codesign --verify --strict"

    if [[ -e "$TARGET" ]]; then
        mv "$TARGET" "$OLD"
    fi
    mv "$tmp" "$TARGET"
    PENDING_TMP=""
    rm -rf "$OLD"
    say "installed $TARGET (version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist"))"
    kv installed "$TARGET"
    kv codesign "$(codesign -dv "$TARGET" 2>&1 | awk -F= '/^(Signature|TeamIdentifier|Authority)=/{printf "%s=%s;", $1, $2}')"

    if [[ $restart -eq 1 ]]; then
        restart_audio || { kv result "on-disk-not-loaded"; exit 3; }
        wait_driver_host
    fi
    kv result "ok"
}

cmd_uninstall() {
    require_root
    local restart=1
    [[ "${1:-}" == "--no-restart" ]] && restart=0
    [[ ! -L "$TARGET" ]] || die "$TARGET is a symlink; refusing"
    if [[ -e "$TARGET" ]]; then
        is_ours "$TARGET" || die "$TARGET is not ours; refusing"
        rm -rf "$TARGET"
        say "removed $TARGET"
    else
        say "$TARGET not installed"
    fi
    [[ -e "$OLD" ]] && is_ours "$OLD" && rm -rf "$OLD"
    local t
    for t in "$TMP_PREFIX"*; do
        [[ -e "$t" ]] && is_ours "$t" && rm -rf "$t"
    done
    if [[ $restart -eq 1 ]]; then
        restart_audio || { kv result "removed-still-loaded"; exit 3; }
    fi
    kv result "ok"
}

cmd_status() {
    kv hal_dir "$HAL_DIR"
    if [[ -e "$TARGET" ]]; then
        kv installed "$TARGET"
        kv bundle_id "$(bundle_id "$TARGET")"
        kv version "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist" 2>/dev/null || echo '?')"
        kv mic_mode "$(/usr/libexec/PlistBuddy -c 'Print :TalkTalkMicMode' "$TARGET/Contents/Info.plist" 2>/dev/null || echo '?')"
        kv owner "$(stat -f '%Su:%Sg %Sp' "$TARGET")"
        kv xattrs "$(xattr_summary "$TARGET")"
        kv codesign "$(codesign -dv "$TARGET" 2>&1 | awk -F= '/^(Signature|TeamIdentifier|Authority)=/{printf "%s=%s;", $1, $2}')"
        kv archs "$(lipo -archs "$TARGET/Contents/MacOS/$TT_DRIVER_EXECUTABLE" 2>/dev/null || echo '?')"
    else
        kv installed "no"
    fi
    kv coreaudiod_pid "$(coreaudiod_pid || true)"
    kv driver_host_pid "$(driver_host_pid || true)"
    kv result "ok"
}

case "${1:-}" in
    install) shift; cmd_install "$@" ;;
    uninstall) shift; cmd_uninstall "$@" ;;
    restart-audio)
        require_root
        restart_audio || { kv result "restart-failed"; exit 3; }
        wait_driver_host
        kv result "ok"
        ;;
    status) cmd_status ;;
    *) sed -n '2,32p' "$0"; exit 2 ;;
esac
