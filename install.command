#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
source_app="$task_root/ExternalBrightness.app"
destination_app="$HOME/Applications/ExternalBrightness.app"
label="local.ychen.ExternalBrightness"
user_id="$(id -u)"
agent="$HOME/Library/LaunchAgents/$label.plist"
if [ ! -x "$source_app/Contents/MacOS/ExternalBrightness" ]; then bash "$task_root/build.command"; fi
if [ -d "$destination_app" ]; then
    installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination_app/Contents/Info.plist")"
    if [ "$installed_id" != "$label" ]; then printf 'An unrelated app exists at %s; installation stopped.\n' "$destination_app"; exit 1; fi
    "$destination_app/Contents/MacOS/ExternalBrightness" --request-quit
fi
launchctl bootout "gui/$user_id/$label" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
temporary_app="$HOME/Applications/.ExternalBrightness-install-$$.app"
trap 'rm -rf "$temporary_app"' EXIT
ditto --norsrc --noextattr "$source_app" "$temporary_app"
xattr -cr "$temporary_app"
codesign --verify --strict "$temporary_app"
if [ -d "$destination_app" ]; then
    backup_app="$HOME/Applications/ExternalBrightness-backup-$(date +%Y%m%d-%H%M%S).app"
    mv "$destination_app" "$backup_app"
fi
mv "$temporary_app" "$destination_app"
"$destination_app/Contents/MacOS/ExternalBrightness" --register-login
launchctl enable "gui/$user_id/$label"
launchctl bootstrap "gui/$user_id" "$agent"
printf 'Installed and started: %s\n' "$destination_app"
printf 'Grant Accessibility to 外接屏亮度 (ExternalBrightness) to enable keyboard brightness keys.\n'
