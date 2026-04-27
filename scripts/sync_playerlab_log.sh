#!/usr/bin/env bash
# sync_playerlab_log.sh
#
# Copies the PlayerLab log from the iOS Simulator app container to
# logs/playerlab.log inside the project, so Claude can read it directly.
#
# Run from your terminal (not from Claude's sandbox — xcrun lives on your Mac):
#
#   cd /path/to/CinemaScope
#   ./scripts/sync_playerlab_log.sh
#
# After running this, Claude can read the log at:
#   logs/playerlab.log  (relative to project root)

set -euo pipefail

BUNDLE_ID="SMR.CinemaScope"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DST="$PROJECT_DIR/logs/playerlab.log"

# Find the booted simulator's app container
CONTAINER=$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null || true)

if [ -z "$CONTAINER" ]; then
    echo "❌  Could not find app container for $BUNDLE_ID"
    echo "    Make sure the iOS Simulator is booted and the app has been launched."
    exit 1
fi

LOG_SRC="$CONTAINER/tmp/playerlab.log"

if [ ! -f "$LOG_SRC" ]; then
    echo "⚠️  Log file not found at: $LOG_SRC"
    echo "    Launch the app first — PlayerLabLog.setup() creates it on startup."
    exit 1
fi

mkdir -p "$(dirname "$LOG_DST")"
cp "$LOG_SRC" "$LOG_DST"

echo "✅  Log synced: $LOG_DST"
echo "    Lines: $(wc -l < "$LOG_DST")"
echo "    Size:  $(wc -c < "$LOG_DST") bytes"
echo ""
echo "Tell Claude: 'log is ready' and it will read it directly."
