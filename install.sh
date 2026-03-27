#!/usr/bin/env bash
# Install skill-sync: sets up the daily cron via macOS LaunchAgent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.skill-sync.daily"
PLIST_SRC="$SCRIPT_DIR/${PLIST_NAME}.plist"
PLIST_DST="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"

if [ ! -f "$PLIST_SRC" ]; then
    echo "Error: $PLIST_SRC not found"
    exit 1
fi

# Unload existing if present
launchctl unload "$PLIST_DST" 2>/dev/null || true

# Generate plist with actual paths
sed "s|__INSTALL_PATH__|$SCRIPT_DIR|g" "$PLIST_SRC" > "$PLIST_DST"

# Load
launchctl load "$PLIST_DST"

echo "Installed. Skill sync will run daily at 8am."
echo "  Plist: $PLIST_DST"
echo "  Script: $SCRIPT_DIR/sync-skills.sh"
echo ""
echo "Run now:     $SCRIPT_DIR/sync-skills.sh"
echo "Seed first:  $SCRIPT_DIR/sync-skills.sh --seed"
echo "Uninstall:   launchctl unload $PLIST_DST && rm $PLIST_DST"
