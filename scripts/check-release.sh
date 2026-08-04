#!/usr/bin/env bash
#
# Pre-publish gate: every version-pinned surface must agree with the release
# being built, before any of it goes out.
#
# This exists because each of the following happened, silently, because nothing
# compared the pinned value to the actual release:
#
#   * the landing page advertised 0.8.1 while 0.8.2 was shipped, so the
#     "Download for macOS" button pointed at the previous DMG;
#   * a cask pinned "<short>" instead of "<short>,<build>", which fails
#     `brew audit --online` and breaks Homebrew's autobump;
#   * a cask's sha256 outlived its DMG, so `brew install` 404s;
#   * install instructions omitted `brew trust`, which Homebrew 6+ requires —
#     the documented commands simply did not work.
#
# All of it is mechanically checkable. So check it, rather than remembering.
#
# Usage:  ./scripts/check-release.sh
#         Run automatically by publish.sh before the publish stage.
set -uo pipefail
cd "$(dirname "$0")/.."

fail() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; FAILED=1; }
FAILED=0

VERSION="$(perl -ne 'print $1 if /MARKETING_VERSION:\s*"([^"]+)"/' app/project.yml | head -1)"
BUILD="$(perl -ne 'print $1 if /CURRENT_PROJECT_VERSION:\s*"([^"]+)"/' app/project.yml | head -1)"
[ -n "$VERSION" ] || { fail "could not read MARKETING_VERSION from app/project.yml"; exit 1; }
[ -n "$BUILD" ] || { fail "could not read CURRENT_PROJECT_VERSION from app/project.yml"; exit 1; }

DMG="dist/Baton-${VERSION}.dmg"

# --- Homebrew cask ------------------------------------------------------------
CASK="Casks/baton.rb"
if [ -f "$CASK" ]; then
    CASK_VERSION="$(sed -nE 's/^  version "([^"]+)".*/\1/p' "$CASK" | head -1)"
    CASK_SHA="$(sed -nE 's/^  sha256 "([0-9a-f]{64})".*/\1/p' "$CASK" | head -1)"
    WANT="${VERSION},${BUILD}"
    if [ "$CASK_VERSION" != "$WANT" ]; then
        fail "cask version '$CASK_VERSION' != '$WANT'
       The appcast carries both sparkle:shortVersionString and sparkle:version, so
       Homebrew's Sparkle livecheck reports them joined. Pin '<short>,<build>' and
       use #{version.csv.first} in the URL, or brew audit --online fails."
    fi
    # Only comparable once the DMG for THIS version exists (publish.sh builds it
    # before calling this gate; a bare run before building skips the hash check).
    if [ -f "$DMG" ]; then
        DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
        if [ "$CASK_SHA" != "$DMG_SHA" ]; then
            fail "cask sha256 does not match $DMG
       cask: ${CASK_SHA:-missing}
       dmg : $DMG_SHA"
        fi
    fi
    for doc in README.md FAQ.md; do
        if [ -f "$doc" ] && grep -q "brew install --cask" "$doc" && ! grep -q "brew trust" "$doc"; then
            fail "$doc gives brew install steps but omits 'brew trust'
       Homebrew 6+ refuses third-party taps without it, so the instructions fail."
        fi
    done
fi

# --- Landing page ------------------------------------------------------------
# publish-site.sh rsyncs the CHECKED-IN html verbatim (no rendering), so a stale
# source is what users see.
SITE="website/index.html"
if [ -f "$SITE" ]; then
    STALE="$(grep -oE "Baton-[0-9]+\.[0-9]+\.[0-9]+\.dmg|Version [0-9]+\.[0-9]+\.[0-9]+" "$SITE" \
        | grep -v "$VERSION" | sort -u || true)"
    if [ -n "$STALE" ]; then
        fail "$SITE still references versions other than $VERSION:
$(printf '       %s\n' $STALE)
       publish.sh step 4d syncs this; a stale source downgrades the live page."
    fi
fi

# --- Appcast (when one has been generated) ------------------------------------
APPCAST="dist/appcast.xml"
if [ -f "$APPCAST" ]; then
    AC_VERSION="$(perl -0ne 'if (/<sparkle:shortVersionString>([^<]+)</) { print $1; exit }' "$APPCAST")"
    AC_BUILD="$(perl -0ne 'if (/<sparkle:version>(\d+)</) { print $1; exit }' "$APPCAST")"
    [ "$AC_VERSION" = "$VERSION" ] || fail "appcast version '${AC_VERSION:-missing}' != '$VERSION'"
    [ "$AC_BUILD" = "$BUILD" ] || fail "appcast build '${AC_BUILD:-missing}' != '$BUILD'"
fi

# --- What's New ---------------------------------------------------------------
# The panel is a version-pinned surface like any other, and it rots the same way:
# it sat at 0.8.1 while 0.9.1 shipped — three releases of user-visible change that
# never reached the one screen built to announce them. WhatsNewFreshnessTests catches
# drift in CI; this makes it impossible to *publish* a release without its entry.
WHATSNEW="app/Sources/Baton/Shell/Music/BatonHelpContent.swift"
if [ -f "$WHATSNEW" ]; then
    if ! grep -q "version: \"$VERSION\"" "$WHATSNEW"; then
        fail "What's New has no entry for $VERSION.
       Add one to HelpWhatsNewRelease.all in $WHATSNEW —
       users see this panel, and shipping without it means the release is silent."
    fi
fi

# --- Conversation eval --------------------------------------------------------
# Agent mode's quality lives in a place no unit test can reach: whether ordinary
# sentences produce the right action and a reply worth reading. The 109-message
# eval is the only thing that measures it, and it caught a regression the whole
# suite passed over — 72 of 109 messages answering a question by playing music.
#
# It cannot be a hard gate: it needs a live model, costs real requests, and is
# nondeterministic. So this warns loudly instead, and records which version was
# last measured. A release that changes the prompt, the tools, or the loop
# without a fresh number is a release shipping on hope.
EVAL_STAMP="$HOME/.baton-eval-last.json"
if grep -rq "isAgentEnabled" app/Sources/Baton/Remote/ 2>/dev/null; then
    STAMPED="$( [ -f "$EVAL_STAMP" ] && perl -0ne 'if (/"version"\s*:\s*"([^"]+)"/) { print $1 }' "$EVAL_STAMP" )"
    if [ "$STAMPED" != "$VERSION" ]; then
        printf '\033[33m! conversation eval not run for %s (last: %s)\033[0m\n' \
            "$VERSION" "${STAMPED:-never}" >&2
        echo "    ./scripts/test.sh -only-testing:BatonTests/RemoteAgentConversationEval" >&2
        echo "    (needs ~/.baton-live-agent.json — see RemoteAgentLiveTests)" >&2
    else
        SCORE="$(perl -0ne 'if (/"correct"\s*:\s*(\d+)/) { print $1 }' "$EVAL_STAMP")"
        echo "    conversation eval: ${SCORE:-?}/109 on this version"
    fi
fi

if [ "$FAILED" -ne 0 ]; then
    printf '\033[31m✗ release gate failed — fix the above before publishing.\033[0m\n' >&2
    exit 1
fi
printf '\033[32m✓ release gate ok: %s (build %s)\033[0m\n' "$VERSION" "$BUILD"
echo "    cask + landing page + appcast + What's New + install docs all match this release"
