#!/bin/bash
# Notarize and staple the installed TinyRecorder.app so other people can run it
# without Gatekeeper warnings. Requires:
#   1. A Developer ID-signed build (run ./build.sh with a Developer ID cert).
#   2. Notary credentials stored ONCE in the keychain (no secrets live in this
#      file). Create an app-specific password at https://appleid.apple.com →
#      Sign-In & Security → App-Specific Passwords, then run:
#
#        xcrun notarytool store-credentials tinyrecorder-notary \
#          --apple-id "you@example.com" \
#          --team-id  "YOURTEAMID" \
#          --password "xxxx-xxxx-xxxx-xxxx"
#
# After that, just run: ./notarize.sh
set -euo pipefail

# Honor the same install-dir override build.sh uses (expand a leading ~).
INSTALL_DIR="${TINYRECORDER_INSTALL_DIR:-/Applications}"
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
APP="${INSTALL_DIR}/TinyRecorder.app"
PROFILE="tinyrecorder-notary"
ZIP="$(mktemp -d)/TinyRecorder.zip"

if [ ! -d "$APP" ]; then
    echo "✗ $APP not found. Run ./build.sh first." >&2
    exit 1
fi

# Refuse to notarize an ad-hoc build — Apple will reject it.
if ! codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "✗ $APP is not Developer ID-signed. Install your cert and re-run ./build.sh." >&2
    exit 1
fi

echo "→ Zipping app for submission..."
ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ Submitting to Apple notary service (this can take a few minutes)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "→ Stapling ticket to the app..."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

rm -f "$ZIP"
echo "✅ Notarized & stapled: $APP"
