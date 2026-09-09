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

# --- The build number must actually increase ----------------------------------
# Sparkle compares sparkle:version — the build number — and ignores
# shortVersionString entirely when deciding whether an update exists. 0.14.0 and
# 0.15.0 both shipped as build 57, so to every installed 0.14.0 copy the new
# release simply wasn't newer: no update was ever offered, no error was ever
# shown, and the appcast looked perfectly correct. Nothing here caught it, because
# every other check compares this release against *itself*. This one compares it
# against the last one that shipped.
PREV_TAG="$(git tag --list 'v*' --sort=-v:refname | grep -v "^v${VERSION}\$" | head -1)"
if [ -n "$PREV_TAG" ]; then
    PREV_BUILD="$(git show "$PREV_TAG:app/project.yml" 2>/dev/null \
        | perl -ne 'print $1 if /CURRENT_PROJECT_VERSION:\s*"([^"]+)"/' | head -1)"
    case "${PREV_BUILD:-x}" in
        (*[!0-9]*|'') : ;;   # unreadable or pre-dates the field — nothing to compare
        (*)
            if [ "$BUILD" -le "$PREV_BUILD" ]; then
                fail "build $BUILD is not greater than $PREV_BUILD (shipped in $PREV_TAG)
       Sparkle compares sparkle:version, so this release would never be offered
       to anyone running $PREV_TAG. Bump CURRENT_PROJECT_VERSION in app/project.yml."
            fi
            ;;
    esac
fi

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

# --- Both hostnames must serve the same appcast -------------------------------
# TBX-5306. The site moved to batonmusic.app, but SUFeedURL is compiled into the
# app and every Mac build up to 0.18.1 polls https://baton.tonebox.io/appcast.xml
# and nothing else. That hostname is the only route to those machines. If it ever
# stops serving the appcast — a tidied vhost, an expired cert, a DNS record
# reclaimed — those installs go quiet permanently, with no error shown to anyone
# and no way to reach them afterwards.
#
# Nothing else would notice, which is the whole reason this check exists. It runs
# BEFORE the upload, so it compares what the two hosts are serving right now (the
# previous release), and the question it answers is "are these two still the same
# document" rather than anything about the release being built.
#
# Not measurable is not the same as broken, so: neither host reachable is a SKIP
# (no network, or the laptop is offline). The new host answering while the old one
# does not is a FAILURE, because that is exactly the shape of the accident.
APPCAST_NEW="https://batonmusic.app/appcast.xml"
APPCAST_OLD="https://baton.tonebox.io/appcast.xml"
fetch_sha() {  # prints the sha256 of the body, or nothing if the fetch failed
    curl -fsS --max-time 20 "$1" 2>/dev/null | shasum -a 256 | awk '{print $1}'
}
SHA_NEW="$(fetch_sha "$APPCAST_NEW")"
SHA_OLD="$(fetch_sha "$APPCAST_OLD")"
EMPTY_SHA="$(printf '' | shasum -a 256 | awk '{print $1}')"
[ "$SHA_NEW" = "$EMPTY_SHA" ] && SHA_NEW=""
[ "$SHA_OLD" = "$EMPTY_SHA" ] && SHA_OLD=""
if [ -z "$SHA_NEW" ] && [ -z "$SHA_OLD" ]; then
    printf '\033[33m~ appcast host check SKIPPED: neither host answered (offline?)\033[0m\n' >&2
    echo "    $APPCAST_NEW" >&2
    echo "    $APPCAST_OLD" >&2
elif [ -z "$SHA_OLD" ]; then
    fail "$APPCAST_OLD is not serving the appcast, but $APPCAST_NEW is.
       Every Mac up to 0.18.1 has that URL compiled in as SUFeedURL and polls
       nothing else. Restore the old vhost before publishing, or those installs
       will never be offered another update. See deploy/README.md, TBX-5306."
elif [ -z "$SHA_NEW" ]; then
    fail "$APPCAST_NEW is not serving the appcast, but $APPCAST_OLD is.
       New builds ship SUFeedURL on batonmusic.app (app/project.yml)."
elif [ "$SHA_NEW" != "$SHA_OLD" ]; then
    fail "the two hostnames serve different appcast documents:
       $APPCAST_NEW  $SHA_NEW
       $APPCAST_OLD  $SHA_OLD
       They point at one nginx docroot (deploy/nginx/default.conf), so a
       difference means a stale cache or a half-finished deploy. Older installs
       poll the old host and would be offered different bits from everyone else."
else
    echo "    appcast identical on both hosts (${SHA_NEW:0:12}…)"
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
        # Read the total from the stamp rather than hardcoding it. The literal used to be
        # 109 while the eval had grown to 116 cases, so 0.17.2 reported "111/109" — a
        # fraction above 1, which reads as a broken measurement rather than as the 95.7%
        # it actually was. A denominator that drifts silently is worse than no denominator.
        TOTAL="$(perl -0ne 'if (/"total"\s*:\s*(\d+)/) { print $1 }' "$EVAL_STAMP")"
        echo "    conversation eval: ${SCORE:-?}/${TOTAL:-?} on this version"
    fi
fi

if [ "$FAILED" -ne 0 ]; then
    printf '\033[31m✗ release gate failed — fix the above before publishing.\033[0m\n' >&2
    exit 1
fi
printf '\033[32m✓ release gate ok: %s (build %s)\033[0m\n' "$VERSION" "$BUILD"
echo "    cask + landing page + appcast + What's New + install docs all match this release"
