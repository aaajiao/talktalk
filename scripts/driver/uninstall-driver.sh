#!/bin/bash
# Remove TalkTalkAudio.driver and restart coreaudiod (ARCHITECTURE.md, "平台与模块").
#
#   sudo scripts/driver/uninstall-driver.sh [--no-restart]
#
# Before running: make sure no meeting app is using TalkTalk Mic and that the system default
# input is not TalkTalk Mic (System Settings > Sound > Input); after removal, apps that were
# using it fall back to a physical microphone.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/install-driver.sh" uninstall "$@"
