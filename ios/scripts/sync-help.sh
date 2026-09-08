#!/bin/bash
#
# Put the canonical HELP.md / FAQ.md where the iPhone target expects to bundle them,
# BEFORE `xcodegen generate` runs.
#
# WHY THIS EXISTS (TBX-3928, 2026-09-07). `ios/project.yml` already copies both files
# into `ios/Resources/` in a preBuildScript, and that keeps them fresh on every build.
# What it cannot do is make them exist in time: xcodegen enumerates `Resources/` when it
# GENERATES the project, so on a tree where those two files are not on disk yet the
# generated .xcodeproj has no reference to them, nothing bundles them, and the prebuild
# step then writes two files the app will never see.
#
# They are gitignored — deliberately, and it should stay that way. The Mac keeps tracked
# copies, but `testflight.sh` refuses a dirty tree and the release guard pins the tree for
# 15 minutes, so a generated file that the build rewrites under itself would turn every
# edit to the root HELP.md into a release that aborts halfway.
#
# The cost of the two together was a clean checkout that builds an iPhone app with no help
# in it. `SettingsHelpLinkTests` catches it — "the prebuild step copies HELP.md and FAQ.md
# in — without them every link below is vacuous" — and it caught this, on the first release
# cut from a dedicated worktree, which is what CLAUDE.md tells you to do.
#
# Idempotent and instant, so every caller can just run it.
set -euo pipefail
IOS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$IOS/.." && pwd)"

mkdir -p "$IOS/Resources"
for guide in HELP.md FAQ.md; do
  [ -f "$REPO/$guide" ] || { echo "ERROR: $REPO/$guide is missing" >&2; exit 1; }
  cp "$REPO/$guide" "$IOS/Resources/$guide"
done
