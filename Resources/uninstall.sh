#!/bin/bash
# Manual driver recovery. Full removal lives in Settings > Components > Completely uninstall.
# Run as the logged-in user; only the existing, identity-checking driver script gets sudo.
set -euo pipefail
resource_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  --help|"")
    /bin/echo "Usage: uninstall.sh --driver-only --confirm-no-meeting [--no-restart]"
    /bin/echo "First leave all calls, quit TalkTalk, and select a physical microphone in System Settings > Sound > Input."
    /bin/echo "This removes only TalkTalkAudio.driver; see the bundled README.md for full manual cleanup."
    exit 0 ;;
  --driver-only) shift ;;
  *) /bin/echo "Unknown option. Run uninstall.sh --help." >&2; exit 2 ;;
esac
[ "${1:-}" = --confirm-no-meeting ] || { /bin/echo "Confirm the no-meeting/default-input checks with --confirm-no-meeting." >&2; exit 2; }
shift
[ "$EUID" -ne 0 ] || { /bin/echo "Run as your ordinary user, not sudo; the driver step requests sudo itself." >&2; exit 1; }
if [ $# -gt 1 ] || { [ $# -eq 1 ] && [ "$1" != --no-restart ]; }; then
  /bin/echo "Only --no-restart is accepted after confirmation." >&2; exit 2
fi
restore_record="${TALKTALK_HOME:-$HOME/Library/Application Support/TalkTalk}/sysinput-restore.json"
if [ -e "$restore_record" ] || [ -L "$restore_record" ]; then
  /bin/echo "A default-input restore record remains. Use TalkTalk's Restore default input action first (see README.md if the app was removed)." >&2
  exit 1
fi
if [ -f "$resource_dir/driver/install-driver.sh" ]; then
  driver_script="$resource_dir/driver/install-driver.sh"
else
  driver_script="$resource_dir/../scripts/driver/install-driver.sh"
fi
[ -f "$driver_script" ] || { /bin/echo "The validated driver uninstaller is missing; use the repository's scripts/driver/uninstall-driver.sh." >&2; exit 1; }
exec /usr/bin/sudo /bin/bash "$driver_script" uninstall "$@"
