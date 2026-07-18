#!/usr/bin/env bash
# Baton — FAST local dev loop.
#
# Regenerates the Xcode project (XcodeGen auto-discovers new Swift files), builds
# a Debug build into a scratch derived-data dir, and launches it. Mirrors
# Tonebox's devrun but with no code-signing/Keychain gymnastics — Baton is a free
# standalone player with no synced Keychain state to protect.
#
# Usage:  ./scripts/devrun.sh        (build + relaunch)
set -euo pipefail
cd "$(dirname "$0")/../app"

BUILD_DIR="/tmp/baton-build"
APP="$BUILD_DIR/Build/Products/Debug/Baton.app"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

bold "==> Regenerating project (xcodegen)"
xcodegen generate

bold "==> Building (Debug, incremental)"
xcodebuild build \
    -scheme Baton \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'platform=macOS' \
    -quiet

[[ -d "$APP" ]] || { echo "error: no app at $APP" >&2; exit 1; }

bold "==> Launching Baton"
# Relaunch cleanly so the new build replaces any running instance.
pkill -x Baton 2>/dev/null || true
open "$APP"
