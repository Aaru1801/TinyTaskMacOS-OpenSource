#!/bin/bash
# Build TinyRecorder.app and install it to /Applications.
#
# Why /Applications: macOS ties Accessibility / Input Monitoring (TCC) grants to a
# bundle's path *and* code signature. A single bundle at the standard, immutable
# location is the most reliable place for those grants to persist — far better
# than running a copy out of ~/Documents, and it avoids the "every copy needs its
# own grant" trap.
#
# Signing: if a "Developer ID Application" certificate is installed, this script
# signs with it (hardened runtime) — a stable identity, so TCC grants persist
# across rebuilds and the app can be notarized (see notarize.sh). Until then it
# ad-hoc signs, where TCC falls back to the binary's ever-changing cdhash and may
# re-prompt for permissions after each rebuild.
set -euo pipefail

APP_NAME="TinyRecorder"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${ROOT}/.build/release"
STAGE="${ROOT}/.build/${APP_NAME}.app"        # assembled here first (gitignored)
# Install location can be overridden (e.g. to build a one-off copy on the Desktop
# without disturbing the /Applications install). Expand a leading ~ ourselves —
# parameter expansion does not, and an unexpanded ~ would create a literal "~"
# directory that later rm -rf / cp target by mistake.
INSTALL_DIR="${TINYRECORDER_INSTALL_DIR:-/Applications}"
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
APP_BUNDLE="${INSTALL_DIR}/${APP_NAME}.app"   # final location
CONTENTS="${STAGE}/Contents"

cd "$ROOT"

# Regenerate the icon if the source script is newer than the .icns (or it's missing).
if [ ! -f "AppIcon.icns" ] || [ "tools/make_icon.swift" -nt "AppIcon.icns" ]; then
    echo "→ Generating AppIcon.icns..."
    swift tools/make_icon.swift
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi

echo "→ Compiling (release)..."
# Extra swiftc flags can be injected, e.g. TINYRECORDER_SWIFT_FLAGS="-Xswiftc -DHIDE_PERMISSION_BANNER".
# Unquoted on purpose so multiple flags word-split into separate arguments.
swift build -c release ${TINYRECORDER_SWIFT_FLAGS:-}

echo "→ Bundling ${APP_NAME}.app..."
rm -rf "$STAGE"
mkdir -p "${CONTENTS}/MacOS"
mkdir -p "${CONTENTS}/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${CONTENTS}/MacOS/${APP_NAME}"
cp "${ROOT}/Info.plist" "${CONTENTS}/Info.plist"
cp "${ROOT}/AppIcon.icns" "${CONTENTS}/Resources/AppIcon.icns"
chmod +x "${CONTENTS}/MacOS/${APP_NAME}"

# Stamp a monotonically-increasing build number (before signing — editing the
# plist afterwards would invalidate the signature).
BUILD_NUM=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "${CONTENTS}/Info.plist"

echo "→ Installing to ${INSTALL_DIR}..."
rm -rf "$APP_BUNDLE"
mkdir -p "$INSTALL_DIR"
cp -R "$STAGE" "$APP_BUNDLE"

# Sign the bundle, stripping extended attributes first. Writing into a
# Finder-watched dir (e.g. ~/Desktop) can race in com.apple.FinderInfo/macl that
# codesign rejects as "detritus", so clear-then-sign with one retry.
#   sign_app <identity> [extra codesign flags...]   (identity "-" = ad-hoc)
# Flags are passed as separate positional args and forwarded via "$@", so each is
# quoted correctly even if it ever contains a path with spaces.
sign_app() {
    local id="$1"; shift
    xattr -cr "$APP_BUNDLE" 2>/dev/null || true
    if ! codesign --force "$@" --sign "$id" "$APP_BUNDLE" 2>/dev/null; then
        echo "  …xattr race; clearing and retrying"
        xattr -cr "$APP_BUNDLE" 2>/dev/null || true
        codesign --force "$@" --sign "$id" "$APP_BUNDLE"
    fi
}

# Prefer a Developer ID Application identity when one is installed: a stable
# signature means TCC (Accessibility / Input Monitoring) grants persist across
# rebuilds, and it's a prerequisite for notarization. Override by exporting
# TINYRECORDER_SIGN_ID="Developer ID Application: Name (TEAMID)". Falls back to
# ad-hoc signing until a Developer ID cert exists (then grants re-prompt per build).
# List identities once. The trailing `|| true` on each pipeline matters: under
# `set -euo pipefail` a grep with no match exits non-zero and would abort the
# build, so we swallow that and just end up with an empty SIGN_ID.
SIGN_IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
SIGN_ID="${TINYRECORDER_SIGN_ID:-}"
# 1) Prefer a Developer ID Application cert — distribution-ready & notarizable.
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(printf '%s\n' "$SIGN_IDS" | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"$/\1/' || true)
fi
# 2) Otherwise any stable identity (e.g. Apple Development) — not for distribution,
#    but a stable code signature is enough for TCC grants to persist across rebuilds.
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(printf '%s\n' "$SIGN_IDS" | grep -E "Apple Development|Apple Distribution" | head -1 | sed -E 's/.*"(.*)"$/\1/' || true)
fi

if [ -n "$SIGN_ID" ]; then
    case "$SIGN_ID" in
        *"Developer ID"*)
            echo "→ Signing with Developer ID (hardened runtime): ${SIGN_ID}"
            sign_app "$SIGN_ID" --options runtime --timestamp
            ;;
        *)
            echo "→ Signing with stable identity (TCC grants persist): ${SIGN_ID}"
            sign_app "$SIGN_ID"
            ;;
    esac
    SIGNED_WITH="$SIGN_ID"
else
    echo "→ No signing identity found — ad-hoc signing (permissions re-prompt per rebuild)."
    sign_app "-"
    SIGNED_WITH="ad-hoc"
fi

echo
echo "✅ Installed: ${APP_BUNDLE}"
echo "   Signed:   ${SIGNED_WITH}"
echo "   Run:  open \"${APP_BUNDLE}\""
