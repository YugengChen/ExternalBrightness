#!/bin/bash
set -euo pipefail
app_path="$HOME/Applications/ExternalBrightness.app"
label="local.ychen.ExternalBrightness"
if [ -d "$app_path" ]; then
    installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
    if [ "$installed_id" != "$label" ]; then printf 'Unrelated app found; stopped.\n'; exit 1; fi
    "$app_path/Contents/MacOS/ExternalBrightness" --request-quit
fi
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist"
if [ -d "$app_path" ]; then rm -rf "$app_path"; fi
printf 'ExternalBrightness uninstalled. Preferences and diagnostics retained.\n'

