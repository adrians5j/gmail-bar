#!/usr/bin/env bash
# Builds GmailBar.app. Pass "install" to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/GmailBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/GmailBar "$APP/Contents/MacOS/GmailBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x GmailBar || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/GmailBar.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/GmailBar.app
    echo "Installed to ~/Applications/GmailBar.app"
fi
