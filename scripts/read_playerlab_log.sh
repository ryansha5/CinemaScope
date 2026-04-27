#!/usr/bin/env bash
# read_playerlab_log.sh
#
# Finds the CinemaScope iOS Simulator app container and prints (or tails)
# the PlayerLab log file that PlayerLabLog.setup() writes to.
#
# Usage:
#   ./scripts/read_playerlab_log.sh          # print full log
#   ./scripts/read_playerlab_log.sh tail     # live-tail (Ctrl-C to stop)
#   ./scripts/read_playerlab_log.sh path     # print log file path only
#
# Requirements: Xcode + iOS Simulator booted with SMR.CinemaScope installed.

BUNDLE_ID="SMR.CinemaScope"
MODE="${1:-cat}"

# Find the app data container
CONTAINER=$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null)

if [ -z "$CONTAINER" ]; then
    echo "❌  Could not find app container for $BUNDLE_ID"
    echo "    Make sure the iOS Simulator is booted and the app has been launched at least once."
    exit 1
fi

LOG_FILE="$CONTAINER/tmp/playerlab.log"

if [ ! -f "$LOG_FILE" ]; then
    echo "⚠️  Log file not found: $LOG_FILE"
    echo "    Launch the app in the simulator first (PlayerLabLog.setup() creates it on startup)."
    exit 1
fi

case "$MODE" in
    tail)
        echo "📋 Tailing: $LOG_FILE"
        echo "─────────────────────────────────────────"
        tail -f "$LOG_FILE"
        ;;
    path)
        echo "$LOG_FILE"
        ;;
    *)
        echo "📋 Log: $LOG_FILE"
        echo "─────────────────────────────────────────"
        cat "$LOG_FILE"
        ;;
esac
