#!/usr/bin/env bash
#
# The local test gate for Baton.
#
# GitHub Actions is intentionally off (validate locally), so this script is the
# single executable merge/release gate: it regenerates the Xcode project from
# project.yml and runs the full test suite, exiting nonzero on any failure.
# `scripts/publish.sh` runs this before packaging a release.
#
# Usage:
#   ./scripts/test.sh              # regenerate + test (incremental derived data)
#   CLEAN=1 ./scripts/test.sh      # wipe derived data first (release-grade)
#   ./scripts/test.sh -only-testing:BatonTests/ScrobbleTests   # pass-through args
#   ALLOW_NO_TESTS=1 ./scripts/test.sh …   # a run that matches nothing may still pass
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_DIR="app"
PROJECT="$APP_DIR/Baton.xcodeproj"
SCHEME="Baton"
DERIVED="${BATON_DERIVED_DATA:-/tmp/baton-dd}"
LOG="$(mktemp -t baton-test.XXXXXX).log"

bold(){ printf '\033[1m%s\033[0m\n' "$*"; }
red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
# For a check that could not run, as distinct from one that failed. An unmeasurable
# environment is not a broken feature, and it must not read like one.
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

# --- Reading a build failure the way xcodebuild states it --------------------
#
# WHY THIS EXISTS. When a run failed before any test executed, this script printed
# "Compile errors:" and then whatever `grep 'error: '` found — which, on 2026-09-07,
# was nothing at all, twice. The cause was `Command CodeSign failed with a nonzero
# exit code` on an Xcode-provided test dylib (`errSecInternalComponent`, a keychain
# refusal), and the second run added a collateral `Ld` failure that printed no
# diagnostic of its own. Zero `error:` lines in either log. So the report named a
# cause the evidence did not support and then supported it with nothing. (TBX-5139)
#
# That is this file's oldest defect wearing a new coat. It has twice reported a status
# that did not mean what it looked like — a 790-test run as "Executed 4 tests", five
# crashes as "0 failures" — and both times the fix was to read what the tool actually
# said instead of assuming the common case. Here the tool says it plainly, in two
# places: the `The following build commands failed:` block, and the inline
# `Command X failed with a nonzero exit code` lines. Read those.
#
# Compilation, code signing and "the test runner never started" send a reader to three
# different places — your diff, the machine, the test host — and until now all three
# printed identically, which is worst exactly when the tree is innocent.
#
# THE STRUCTURAL HALF, which matters more than the wording: `diagnose_build_failure`
# composes its evidence FIRST and refuses to print a header with nothing under it. An
# empty section is unreachable rather than merely unlikely, so the next unhandled
# failure shape degrades into "the log names no cause, here is its tail" instead of
# into a confident wrong answer. `scripts/test-gate-diagnosis.sh` asserts that on every
# fixture it has, including one deliberately made of nonsense.
#
# TWO SHELL HAZARDS, both of which this file has been bitten by and both of which are
# worse here than anywhere else, because this code only ever runs when something has
# already gone wrong — a crash here replaces a bad diagnosis with none at all:
#
#   * `head` closes the pipe and the producer dies of SIGPIPE (141), which `pipefail`
#     reports as failure and `set -e` turns into a silent exit. That is TBX-5132's bug
#     exactly. So `first_n`/`last_n` below use awk, which reads its input to the end.
#   * a pipeline that legitimately matches nothing also fails under `pipefail`, and an
#     assignment takes that status. Every extractor therefore ends `|| true` and never
#     returns nonzero for "found nothing", which is not an error here.

first_n() { awk -v n="${1:-10}" 'NR <= n'; }
last_n()  { awk -v n="${1:-10}" '{ a[NR % n] = $0 } END { for (i = NR > n ? NR - n + 1 : 1; i <= NR; i++) print a[i % n] }'; }

# Every build command xcodebuild listed as failed, verbatim, from its own summary block.
# "Testing project … with scheme …" is dropped: it is always present and names nothing.
failed_build_commands() {   # $1 = log
  [ -r "${1:-}" ] || return 0
  awk '
    /^The following build commands failed:/ { inblk = 1; next }
    inblk {
      if ($0 ~ /^\t/) { sub(/^\t/, ""); if ($0 !~ /^Testing project /) print; next }
      inblk = 0
    }
  ' "$1" || true
}

# The command NAMES that failed, deduped in first-seen order. Taken from the summary
# block AND from the inline markers, because a log truncated mid-build (a killed run,
# a full disk) can carry the second without ever reaching the first.
failed_command_names() {   # $1 = log
  [ -r "${1:-}" ] || return 0
  { failed_build_commands "$1" | awk '{ print $1 }' || true
    grep -oE 'Command [A-Za-z_][A-Za-z0-9_]* failed with a nonzero exit code' "$1" 2>/dev/null \
      | awk '{ print $2 }' || true
  } | awk 'NF && !seen[$0]++' || true
}

# xcodebuild's command names are build-system internals. Say what they mean.
human_build_command() {   # $1 = command name
  case "$1" in
    CodeSign|CodeSigning)                     printf 'code signing' ;;
    Validate|ValidateEmbeddedBinary)          printf 'validation' ;;
    Ld|Libtool)                               printf 'linking' ;;
    SwiftCompile|SwiftDriver|SwiftEmitModule|CompileC|CompileSwift|CompileSwiftSources)
                                              printf 'compilation' ;;
    PhaseScriptExecution|RuleScriptExecution) printf 'a build script' ;;
    CompileAssetCatalog|CompileXIB|CompileStoryboard|ProcessInfoPlistFile)
                                              printf 'resource processing' ;;
    *)                                        printf '%s' "$1" ;;
  esac
}

# A failing XCTest case also prints `error: `, so the exclusions are what keep a test
# failure from being reported as a compile error — the same confusion, one class over.
compile_error_lines() {   # $1 = log
  [ -r "${1:-}" ] || return 0
  grep -E '(^|[[:space:]])error: ' "$1" 2>/dev/null \
    | grep -vE '^xcodebuild: error:| error: -\[|XCTAssert|recorded an issue' || true
}

# xcodebuild refusing the whole run — an unavailable destination, unresolvable packages,
# a missing scheme. Not a compile error, and not caused by the tree.
tool_error_lines() {   # $1 = log
  [ -r "${1:-}" ] || return 0
  grep -E '^xcodebuild: error:' "$1" 2>/dev/null || true
}

# The build succeeded and the test host still never ran a test. A different place to look
# again: the runner, the simulator, the test bundle's load-time dependencies.
runner_failure_lines() {   # $1 = log
  [ -r "${1:-}" ] || return 0
  grep -E 'Test runner never began executing|Lost connection to the test runner|Failed to background test runner|The test runner exited with code|never finished bootstrapping|Test session ended unexpectedly|Unable to load test bundle|Failed to load the test bundle' \
    "$1" 2>/dev/null || true
}

test_failure_lines() {   # $1 = log
  [ -r "${1:-}" ] || return 0
  grep -E ' error: .*XCTAssert| failed \([0-9]| recorded an issue' "$1" 2>/dev/null || true
}

# One short phrase naming the cause, for the one-line summary. Kept in step with
# `diagnose_build_failure` below by sharing every extractor with it, so the headline
# and the evidence under it cannot disagree.
diagnose_headline() {   # $1 = log
  local log="${1:-}"
  [ -r "$log" ] || { printf 'no log was kept, so nothing can be said about why'; return 0; }
  if grep -q 'Could not resolve package dependencies' "$log" 2>/dev/null; then
    printf 'package resolution failed'; return 0
  fi
  local names; names="$(failed_command_names "$log")"
  if [ -n "$names" ]; then
    local phrase
    phrase="$(printf '%s\n' "$names" \
      | while read -r n; do human_build_command "$n"; printf '\n'; done \
      | awk 'NF && !seen[$0]++ { a[++c] = $0 }
             END { for (i = 1; i <= c; i++) printf "%s%s", a[i], (i < c - 1 ? ", " : (i == c - 1 ? " and " : "")) }')"
    printf 'the build failed at %s' "$phrase"; return 0
  fi
  if compile_error_lines  "$log" | grep -q .; then printf 'compile errors';                 return 0; fi
  if tool_error_lines     "$log" | grep -q .; then printf 'xcodebuild refused the run';     return 0; fi
  if runner_failure_lines "$log" | grep -q .; then printf 'the test runner never started';  return 0; fi
  if test_failure_lines   "$log" | grep -q .; then printf 'tests failed';                   return 0; fi
  printf 'a cause the log does not name'
}

# The full report: what failed, in xcodebuild's own words, with the diagnostic that
# explains it and a pointer to the right place to look.
diagnose_build_failure() {   # $1 = log
  local log="${1:-}"
  if [ ! -r "$log" ]; then
    red "  No log to read — the failure cannot be explained, which is itself the finding."
    return 0
  fi

  local body; body="$(mktemp -t baton-diag.XXXXXX)"
  local lead="" names cmds
  names="$(failed_command_names "$log")"
  cmds="$(failed_build_commands "$log")"

  if grep -q 'Could not resolve package dependencies' "$log" 2>/dev/null; then
    lead="Package resolution failed — this is not a compile error and the tree is probably fine."
    { grep -E "Could not resolve package dependencies|Package.swift|missing or invalid" "$log" 2>/dev/null || true; } \
      | first_n 10 >>"$body"
    { echo
      echo "macOS reaps \$TMPDIR by age and leaves the directory tree standing, so SPM sees"
      echo "resolved checkouts, skips re-resolving, and finds no manifests. Move the derived"
      echo "data aside and re-run:  mv $DERIVED $DERIVED.old"
    } >>"$body"

  elif [ -n "$names" ]; then
    lead="$(diagnose_headline "$log" | sed 's/^the/The/'). No test ran, so no test is implicated."
    { echo "Build commands xcodebuild reported as failed:"
      printf '%s\n' "${cmds:-$names}" | sed 's/^/  /' | first_n 10
    } >>"$body"

    # The diagnostic line sits above the failure marker, not in the summary block, and for
    # codesign — the case that produced this card — it is never an `error:` line.
    local sign_evidence
    sign_evidence="$({ grep -E 'errSec[A-Za-z]+|resource fork, Finder information|no identity found|The specified item could not be found in the keychain|unable to build chain|bundle format unrecognized|code object is not signed' "$log" 2>/dev/null || true; } | sort -u | first_n 5)"
    if [ -n "$sign_evidence" ]; then
      { echo; echo "Signing diagnostics:"; printf '%s\n' "$sign_evidence" | sed 's/^/  /'; } >>"$body"
    fi
    if grep -q 'errSecInternalComponent' "$log" 2>/dev/null; then
      { echo
        echo "errSecInternalComponent is the keychain refusing to sign — commonly another"
        echo "process signing at the same moment, or a locked login keychain. Nothing in the"
        echo "tree can cause it. Re-run before re-reading your diff."
      } >>"$body"
    fi

    local compile_evidence; compile_evidence="$(compile_error_lines "$log" | first_n 20)"
    if [ -n "$compile_evidence" ]; then
      { echo; echo "Compiler diagnostics:"; printf '%s\n' "$compile_evidence" | sed 's/^/  /'; } >>"$body"
    fi
    local link_evidence
    link_evidence="$({ grep -E '^ld: |Undefined symbols?|duplicate symbol|linker command failed' "$log" 2>/dev/null || true; } | first_n 10)"
    if [ -n "$link_evidence" ]; then
      { echo; echo "Linker diagnostics:"; printf '%s\n' "$link_evidence" | sed 's/^/  /'; } >>"$body"
    fi

  elif compile_error_lines "$log" | grep -q .; then
    lead="Compile errors:"
    compile_error_lines "$log" | first_n 20 >>"$body"

  elif tool_error_lines "$log" | grep -q .; then
    lead="xcodebuild refused the run — it never got as far as building the tree."
    tool_error_lines "$log" | first_n 10 >>"$body"

  elif runner_failure_lines "$log" | grep -q .; then
    lead="The test runner never started — the build is fine, the host never ran a test."
    runner_failure_lines "$log" | first_n 10 >>"$body"
    { echo; echo "Look at the test host and its load-time dependencies, not at the diff."; } >>"$body"

  elif test_failure_lines "$log" | grep -q .; then
    lead="Failing cases:"
    test_failure_lines "$log" | last_n 25 >>"$body"
  fi

  # THE INVARIANT. Every branch above composed its evidence into $body before anything
  # was printed, so an empty $body means the log holds nothing this routine understands.
  # Say exactly that and hand over the tail, rather than printing a confident header
  # above nothing — which is the whole defect this block exists to remove.
  if [ ! -s "$body" ]; then
    lead="The build failed and the log names no cause this gate recognises. Its last lines:"
    { grep -v '^[[:space:]]*$' "$log" 2>/dev/null || true; } | last_n 15 >>"$body"
  fi
  if [ ! -s "$body" ]; then
    lead="The build failed and its log is empty ($(wc -c <"$log" | tr -d ' ') bytes) — there is no evidence at all."
    echo "(nothing was captured — check that the command's output was redirected)" >>"$body"
  fi

  red "  $lead"
  sed 's/^/    /' "$body" >&2
  rm -f "$body"
}

# `BATON_DIAGNOSE_LOG` exists so `scripts/test-gate-diagnosis.sh` can drive the routines
# **above** over planted logs, rather than keeping its own copy of them — the same hatch
# `LINT_ONLY` opens for the lints, and for the same reason: a guard that reimplements its
# subject can pass while the subject is broken.
if [ -n "${BATON_DIAGNOSE_LOG:-}" ]; then
  printf 'HEADLINE: %s\n' "$(diagnose_headline "$BATON_DIAGNOSE_LOG")"
  diagnose_build_failure "$BATON_DIAGNOSE_LOG"
  exit 0
fi

# --- "Did this run prove anything?" — one definition, used by both suites -----
#
# Green here means "this tree is safe to merge or publish". A run that executed **no
# tests** has not established that, however cleanly it exited — and exiting cleanly is
# precisely what it does. A typo'd `-only-testing` (this script forwards "$@" straight to
# xcodebuild), a scheme that lost its test targets, or a filter that stopped matching
# after a rename each produce a successful build that asserts nothing, and the gate used
# to print `✓ TESTS PASSED — no tests ran` in green for all three. The summary text was
# honest; the verdict was not.
#
# It is the same lesson this gate has already learned twice, at its limit: the log once
# reported a 790-test run as "Executed 4 tests", and a run with five crashes as "0
# failures". Both were fixed by checking the *count* rather than the tick. Zero is a count.
#
# One function rather than a check at each site, because there are two suites here and
# "when something exists in more than one place, put it in one" is the rule this codebase
# keeps paying to relearn. (TBX-2924)
#
# `ALLOW_NO_TESTS=1` is the escape hatch, and it is deliberately **not** an automatic
# exemption for `-only-testing` runs: a mistyped filter is the likeliest way to arrive
# here, so exempting filtered runs would exempt exactly the case worth catching. Someone
# who genuinely means to run nothing can say so, and it shows up in their shell history.
empty_run_is_failure() { [ -z "${ALLOW_NO_TESTS:-}" ]; }

# --- Counting a run, when a run has two reporters in it ----------------------
#
# WHY THIS EXISTS. `Executed N tests` is the **XCTest** reporter's rollup. Swift-testing
# (the `@Test` macro) never prints that line — it ends with `Test run with N tests in M
# suites` — so a count scraped from that grep describes only half of a suite that has both.
# Measured 2026-09-08 on one iPhone run: the grep said 154, the result bundle said 157, and
# the three it could not see were the `Artwork wash` suite. Nothing was lost; the gate
# simply could not count them, and it could not have counted any `@Test` written since.
# (TBX-5236)
#
# The consequence is this file's oldest defect wearing yet another coat: **delete every
# swift-testing test in the phone suite tomorrow and the gate's iPhone line would not
# move.** A suite that quietly loses tests looks exactly like a healthy one. That is why
# the Mac summary was rebuilt around the result bundle; the iPhone and gateway stages had
# not caught up, and new tests here are more likely to be `@Test` than `XCTestCase`.
#
# `totalTestCount` in the bundle counts BOTH reporters — measured, not assumed, on
# ~/Library/Logs/Baton/gate-failures/2026-09-08_12-34-00: the log's `.xctest` rollups sum
# to 1815, its swift-testing line says 149, and the bundle says 1964. 1815 + 149 = 1964.
#
# All four extractors are pure text over a log or over JSON, so `scripts/test-gate-counts.sh`
# can plant evidence at the REAL routines and assert the number moves when tests are added
# or removed. A count nobody plants a change against is precisely what is being fixed here;
# replacing it with another one would miss the point.

# Every `.xctest` bundle rollup in a log, summed: "<tests> <bundles> <failures>", or nothing.
#
# Keyed by bundle name so a repeated print cannot double it. `tail -2` took the last two
# matching lines regardless of what they were and xcodebuild prints one rollup per *suite*,
# so a green 790-test run was announced as "Executed 4 tests" when the last suite was small;
# "take the largest" then dropped two hundred tests once the scheme gained package bundles.
# The truth is per bundle: each ".xctest" prints exactly one rollup.
xctest_log_counts() {   # $1 = log
  [ -r "${1:-}" ] || return 0
  awk '
    /Test Suite .*\.xctest. (passed|failed) at/ { name = $3; want = 1; next }
    want && /Executed [0-9]+ tests?,/ {
        if (!(name in seen)) {
            seen[name] = 1
            for (i = 1; i <= NF; i++) {
                if ($i == "Executed") tests += $(i + 1)
                if ($(i + 1) ~ /^failures?[,.]?$/) failures += $i
            }
        }
        want = 0
    }
    END { if (length(seen)) printf "%d %d %d\n", tests, length(seen), failures }
  ' "$1"
}

# Swift-testing's own rollup: "<tests> <suites>", or nothing when the run had none.
swift_testing_log_counts() {   # $1 = log
  [ -r "${1:-}" ] || return 0
  # `|| true` is load-bearing, for the same reason it is everywhere else in this file:
  # under `pipefail` a grep that matches nothing fails the pipeline and the caller's
  # assignment takes that status. "This run had no swift-testing tests" is an answer.
  { grep -hoE 'Test run with [0-9]+ tests? in [0-9]+ suites?' "$1" | tail -1 || true; } \
    | awk '{ print $4, $7 }'
}

# What a log says the whole run was, both reporters added up. A number, or nothing at all
# when the log holds neither rollup — which is a build that never reached the tests, and
# must stay distinguishable from a run that executed zero.
log_test_total() {   # $1 = log
  local xctest swift_testing xctest_n swift_testing_n
  xctest="$(xctest_log_counts "$1")"
  swift_testing="$(swift_testing_log_counts "$1")"
  if [ -z "$xctest$swift_testing" ]; then return 0; fi
  xctest_n=0; swift_testing_n=0
  if [ -n "$xctest" ]; then xctest_n="${xctest%% *}"; fi
  if [ -n "$swift_testing" ]; then swift_testing_n="${swift_testing%% *}"; fi
  printf '%d\n' "$((xctest_n + swift_testing_n))"
}

# The counts a result bundle records: "<total> <passed> <failed> <skipped>", or nothing.
# Split from `bundle_counts` so the parse is testable without Xcode, a bundle, or a machine
# that has ever run the suite.
counts_from_summary_json() {   # JSON on stdin
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print("%d %d %d %d" % (d.get("totalTestCount", 0), d.get("passedTests", 0),
                       d.get("failedTests", 0), d.get("skippedTests", 0)))
' 2>/dev/null || true
}

bundle_counts() {   # $1 = .xcresult path
  [ -d "${1:-}" ] || return 0
  { xcrun xcresulttool get test-results summary --path "$1" --compact 2>/dev/null || true; } \
    | counts_from_summary_json
}

# `BATON_COUNT_LOG` / `BATON_COUNT_JSON` exist so `scripts/test-gate-counts.sh` can drive
# the routines **above** over planted evidence rather than keeping a copy of them — the
# same hatch `BATON_DIAGNOSE_LOG` opens, for the same reason: a guard that reimplements its
# subject can pass while the subject is broken. `BATON_COUNT_BUNDLE` is the by-hand one,
# for pointing the real bundle reader at a real result bundle.
if [ -n "${BATON_COUNT_LOG:-}" ]; then
  printf 'XCTEST: %s\n' "$(xctest_log_counts "$BATON_COUNT_LOG")"
  printf 'SWIFTTESTING: %s\n' "$(swift_testing_log_counts "$BATON_COUNT_LOG")"
  printf 'TOTAL: %s\n' "$(log_test_total "$BATON_COUNT_LOG")"
  exit 0
fi
if [ -n "${BATON_COUNT_JSON:-}" ]; then
  printf 'BUNDLE: %s\n' "$(counts_from_summary_json <"$BATON_COUNT_JSON")"
  exit 0
fi
if [ -n "${BATON_COUNT_BUNDLE:-}" ]; then
  printf 'BUNDLE: %s\n' "$(bundle_counts "$BATON_COUNT_BUNDLE")"
  exit 0
fi

bold "==> Generating Xcode project (xcodegen)"
( cd "$APP_DIR" && xcodegen generate >/dev/null )

if [ -n "${CLEAN:-}" ]; then
  bold "==> Wiping derived data ($DERIVED)"
  rm -rf "$DERIVED"
fi

# --- Source lints (fast, fail before the build) ----------------------------
bold "==> Lints"
lint_fail=0
# `BATON_LINT_SRC` and `LINT_ONLY` exist so `scripts/test-lints.sh` can drive **this** block
# over a tree of planted violations rather than keeping its own copy of the patterns. A guard
# that reimplements what it guards drifts from it, and then passes for the wrong reason —
# which is the failure mode this whole file keeps paying for. (TBX-5132)
SRC="${BATON_LINT_SRC:-$APP_DIR/Sources/Baton}"
# CAPTURE, then test — never `producer | grep -q`. (TBX-5132)
#
# Both lints below used to be `grep … | grep -q .` with the *violation* in the `then`
# branch, and under the `set -o pipefail` at the top of this file that shape fails OPEN.
# `grep -q` exits at its first match, the producer dies on the closed pipe with SIGPIPE,
# and pipefail reports 141 — which `if` reads as false, i.e. "no violations found".
#
# Worse than a flake, because it depends on whether the producer's output fits the pipe
# buffer before `grep -q` leaves: a couple of violations pass through and the lint works;
# many violations and the producer is still writing when the pipe closes. **It fails open
# precisely when there is the most to find.** Demonstrated with 8000 planted violations of
# W-16 below — the lint printed nothing and returned success.
#
# W-16 is the one that matters: it is a credential lint (Subsonic auth rides in the query
# string of a URL), so it could pass while the thing it guards was leaking.
#
# `scripts/test-lints.sh` plants real violations and asserts each lint fires, so this
# cannot come back silently.
lint_hits() { grep -rnE "$1" "$SRC" --include='*.swift' || true; }

# W-18: a single log subsystem (io.tonebox.baton) so `log show` captures everything and
# doesn't collide with the Tonebox app. Any other Logger(subsystem:) is a regression.
subsystem_hits="$(lint_hits 'Logger\(subsystem:' | grep -v 'io.tonebox.baton' || true)"
if [ -n "$subsystem_hits" ]; then
  red "  lint: non-baton Logger subsystem found:"
  printf '%s\n' "$subsystem_hits" | sed 's/^/    /' >&2
  lint_fail=1
fi
# W-16: never log a full URL (Subsonic auth rides in the query string).
url_hits="$(lint_hits '(^|[^A-Za-z])[Ll]og[A-Za-z]*\.(error|info|notice|debug|warning|fault|log)\(.*absoluteString')"
if [ -n "$url_hits" ]; then
  red "  lint: a full URL (.absoluteString) is being logged:"
  printf '%s\n' "$url_hits" | sed 's/^/    /' >&2
  lint_fail=1
fi
if [ -n "${LINT_ONLY:-}" ]; then exit "$lint_fail"; fi
[ "$lint_fail" -eq 0 ] && green "  lints clean" || { red "✗ LINT FAILED"; exit 1; }

# --- Release-script guards (fast, no Xcode) ---------------------------------
#
# Both of these were written to stop a specific defect coming back, and until now
# nothing ran either of them:
#
#   test-release-guard.sh   the tree cannot change under a running release, after
#                           a build uploaded as the wrong version (TBX-5058)
#   test-signing-patch.sh   the signing patch does not re-insert keys already in
#                           project.yml, after four releases did (TBX-5066)
#   test-app-store-metadata the App Store metadata tool reconciles the repo against
#                           App Store Connect correctly, driven against a mock so it
#                           needs no credentials and touches no live listing (TBX-5075)
#
# A guard nobody invokes is worse than one that cannot fail, because it still
# reads as coverage. `grep -n test-signing-patch scripts/test.sh` returned nothing
# on the day it was written, and the defect it guards is precisely the kind that
# hides — duplicate YAML keys holding identical values, which xcodegen resolves
# silently and no build ever complains about. (TBX-5073)
#
# They need no Xcode, no simulator and nothing from Apple, and finish in about a
# second each, so they run here rather than behind the iPhone build. They run even
# under SKIP_IOS: that flag means "the quick local loop", which is exactly when a
# release script gets edited without much thought.
#   test-lints             the two source lints above can actually fail — they were
#                          `grep … | grep -q .`, which under pipefail returns 141 on a
#                          match and reads as "nothing found", so a credential lint could
#                          pass while leaking (TBX-5132)
#   test-gate-diagnosis    THIS script's own failure report names the cause the log
#                          states, and never prints a header with nothing under it —
#                          it reported a codesign failure as "Compile errors:" and
#                          then listed none, twice in one afternoon (TBX-5139)
#   test-gate-counts       THIS script counts every test that ran, not just the ones the
#                          XCTest reporter rolls up — it reported a 157-test iPhone run as
#                          154 because swift-testing prints a different line, and would
#                          not have moved if all three had been deleted (TBX-5236)
for guard in test-release-guard test-signing-patch test-app-store-metadata test-lints test-gate-diagnosis test-gate-counts; do
  GUARD_LOG="$(mktemp -t "baton-$guard.XXXXXX").log"
  if [ -x "scripts/$guard.sh" ]; then
    guard_cmd=("scripts/$guard.sh")
  elif [ -x "ios/scripts/$guard.sh" ]; then
    guard_cmd=("ios/scripts/$guard.sh")
  else
    guard_cmd=(python3 "ios/scripts/$guard.py")
  fi
  if "${guard_cmd[@]}" >"$GUARD_LOG" 2>&1; then
    summary="$(grep -oE '[0-9]+ passed[,a-z0-9 ]*' "$GUARD_LOG" | tail -1)"
    green "  $guard: ${summary:-ok}"
    rm -f "$GUARD_LOG"
  else
    red "✗ $guard FAILED — $GUARD_LOG"
    sed 's/^/    /' "$GUARD_LOG" >&2
    exit 1
  fi
done

# --- The Python a RELEASE gets is not the Python this gate gets --------------
#
# `testflight.sh` prepends /usr/bin to PATH so Apple's rsync wins the lookup during
# -exportArchive (Homebrew's rsync makes exportArchive die with a bare "Copy failed").
# That prepend also decides which `python3` the whole release sees: macOS's own 3.9,
# while a developer shell finds Homebrew's. The three release scripts run under the
# release's one.
#
# On 2026-09-07 that difference stopped the 1.1 release at the first stage. Python
# evaluates annotations at def time before 3.10, so `status: int | None` in asc.py
# raised TypeError on import — in asc.py, app-store-metadata.py and attach-build.py
# alike, since both import it. Under a release, and nowhere else: the guard loop
# above had just printed "test-app-store-metadata: 43 passed" for the same files.
# attach-build.py is the one that would have hurt, because it runs AFTER the upload,
# and the whole reason it exists is that a build nobody attaches is invisible to
# testers while looking perfectly fine in App Store Connect. (TBX-3928)
#
# Loading the module is the whole check: the failure is at def time, not at call time.
RELEASE_PYTHON="$(PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" command -v python3)"
RELPY_ERR="$(mktemp -t baton-relpy.XXXXXX).err"
for script in asc app-store-metadata attach-build; do
  if ! "$RELEASE_PYTHON" -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('m', 'ios/scripts/$script.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
" 2>"$RELPY_ERR"; then
    red "✗ ios/scripts/$script.py does not load under the release's Python"
    red "  $RELEASE_PYTHON ($("$RELEASE_PYTHON" --version 2>&1))"
    sed 's/^/    /' "$RELPY_ERR" >&2
    red "  A release runs these with /usr/bin first on PATH. Keep 3.10+ syntax out,"
    red "  or add 'from __future__ import annotations' as asc.py explains."
    exit 1
  fi
done
rm -f "$RELPY_ERR"
green "  release python: ios/scripts/*.py load under $("$RELEASE_PYTHON" --version 2>&1)"

# And the suite itself, under that same Python. The import check above proves the
# modules load; this proves they still behave, which is the half that would otherwise
# only ever be observed mid-release.
if [ "$RELEASE_PYTHON" != "$(command -v python3)" ]; then
  RELPY_LOG="$(mktemp -t baton-relpy.XXXXXX).log"
  if "$RELEASE_PYTHON" ios/scripts/test-app-store-metadata.py >"$RELPY_LOG" 2>&1; then
    green "  release python: test-app-store-metadata $(grep -oE '[0-9]+ passed[,a-z0-9 ]*' "$RELPY_LOG" | tail -1)"
    rm -f "$RELPY_LOG"
  else
    red "✗ test-app-store-metadata FAILS under the release's Python — $RELPY_LOG"
    sed 's/^/    /' "$RELPY_LOG" >&2
    exit 1
  fi
fi

# --- Is the repo's App Store listing still what is published? ----------------
#
# The guard above proves the tool works. This asks the question the tool exists for,
# against the real App Store Connect: has anyone edited the listing in the web form
# since the repo last looked? If so, `ios/metadata/en-US.json` is a lie and
# `AppStoreMetadataTests` has been guarding values nobody ships (TBX-5075).
#
# NOT --strict here, and that is a deliberate asymmetry worth stating. Without ASC
# credentials or a network this prints SKIP and passes, because failing the whole
# suite on a laptop that has no App Store key would teach everyone to bypass the
# gate, and a bypassed gate checks nothing. `testflight.sh` runs the same command
# WITH --strict, so a release cannot skip it — that is where skipping would actually
# cost something.
#
# A pending change (the repo ahead of live, waiting on a release) is reported and
# does not fail. It is the normal state for weeks at a time, and a check that is red
# for a month is one people stop reading.
if [ -f ios/scripts/.testflight.env ]; then
  set -a; . ios/scripts/.testflight.env; set +a
fi
META_LOG="$(mktemp -t baton-metadata.XXXXXX).log"
if python3 ios/scripts/app-store-metadata.py check >"$META_LOG" 2>&1; then
  green "  app-store-metadata: $(grep -oE '(CLEAN|PENDING|SKIP).*' "$META_LOG" | head -1)"
  rm -f "$META_LOG"
else
  red "✗ App Store metadata has DRIFTED from the repo — $META_LOG"
  sed 's/^/    /' "$META_LOG" >&2
  exit 1
fi

# --- iPhone build (cross-platform breakage guard) ---------------------------
#
# This repo ships two apps over shared packages, and until now the gate only ever
# built one of them. Merging the AVAudioEngine work proved what that costs: the
# engine's per-app output routing is CoreAudio HAL, which does not exist on iOS,
# so the iPhone app stopped compiling — while this script reported 1228 tests
# passing and 0 failures over the very same tree. A green gate meant one app was
# healthy, and said nothing at all about the other.
#
# A build, not a test run: the phone's own suite runs on its own hardware and is
# not what leaked. What leaked was compilation of shared code against a second
# SDK, and that is exactly what this catches. Cheap insurance — it runs before
# the long Mac suite so cross-platform breakage fails in minutes, not after.
#
# SKIP_IOS=1 for a fast Mac-only loop while iterating; never for a merge.
if [ -z "${SKIP_IOS:-}" ]; then
  IOS_LOG="$(mktemp -t baton-ios-build.XXXXXX).log"
  # Sibling of the log, so the two are findable together, and a fresh mktemp name each run
  # means xcodebuild never refuses an existing bundle path. Same shape as the Mac stage's.
  IOS_RESULT_BUNDLE="${IOS_LOG%.log}.xcresult"
  # Before generating, not after: xcodegen enumerates ios/Resources/ as it builds the
  # project, and the two guides are gitignored, so on a clean checkout they are absent at
  # that moment and never reach the bundle. See ios/scripts/sync-help.sh. (TBX-3928)
  ./ios/scripts/sync-help.sh
  ( cd ios && xcodegen generate >/dev/null )

  # Prefer running the phone's unit tests on a simulator: that compiles the shared
  # packages against the iOS SDK *and* exercises the phone-only logic (the audio-session
  # rules for the engine, which have no macOS equivalent and which the Mac suite therefore
  # cannot cover). Falls back to a device build where no simulator is installed — still
  # enough to catch the cross-platform compile breakage this step exists for.
  #
  # The UI tests are deliberately NOT here: they drive a real app against Navidrome's
  # public demo server, so a merge would depend on a third party being up, and the whole
  # suite is about 40 minutes against this gate's 8-12.
  #
  # That exclusion is still right, and it used to mean nothing ran them at all — which is
  # how the only test that photographs the Music Friend composer sat broken for an unknown
  # period (TBX-5148). They now run on the **release** path: `testflight.sh` runs a bounded
  # release set through `ios/scripts/ui-tests.sh`, blocking, with skips reported as skips.
  # Same split as the App Store metadata check below, for the same reason.
  #
  #   ./ios/scripts/ui-tests.sh                                   # everything, ~40 min
  #   ./ios/scripts/ui-tests.sh -only BatonMobileUITests/FullWalkUITests
  # Selected by UDID, not by name. A name is resolved by xcodebuild at launch time and
  # gives us nothing to wait on; a UDID is a device we can boot and then block until it is
  # actually ready. See the boot gate below for why that matters.
  IOS_SIM_INFO="$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import sys, json
try:
    devices = json.load(sys.stdin)['devices']
except Exception:
    sys.exit()
for runtime, entries in devices.items():
    if 'iOS' in runtime:
        for entry in entries:
            if 'iPhone' in entry['name']:
                print(entry['udid'] + '\t' + entry['name'])
                sys.exit()
" 2>/dev/null)"
  IOS_SIM_UDID="${IOS_SIM_INFO%%$'\t'*}"
  IOS_SIM="${IOS_SIM_INFO#*$'\t'}"

  set +e
  if [ -n "$IOS_SIM_UDID" ]; then
    # --- Wait for a settled simulator, rather than racing one ------------------
    #
    # Observed 2026-08-12: this stage failed with
    #
    #   FBSOpenApplicationServiceErrorDomain Code=1 "Simulator device failed to launch
    #   io.tonebox.baton" … Busy ("Application failed preflight checks")
    #
    # No compile errors — the app built and SpringBoard refused to start it. In isolation
    # minutes later on the same tree: 110 tests, 0 failures. The trigger is running gates
    # back to back, so the previous run's simulator is still settling when the next one
    # launches. The cost is the whole gate (~15 min), and it lands *before* the Mac suite,
    # so nothing else gets run either.
    #
    # The fix is to WAIT, not to retry. Re-attempting a failed launch is how a gate stops
    # meaning anything — the same principle as the flaky-test rule in CLAUDE.md. So:
    # `bootstatus -b` boots the device if needed and blocks until it reports ready, which
    # is the state xcodebuild would otherwise have assumed. Its own help says it is safe to
    # call before booting has started.
    #
    # Not fatal on its own: if the wait fails, the launch may still work, and turning a
    # healthy run red over a boot probe would be its own version of this bug. The
    # classification below is what makes a genuine launch failure legible.
    bold "==> Waiting for simulator $IOS_SIM to settle ($IOS_SIM_UDID)"
    if xcrun simctl bootstatus "$IOS_SIM_UDID" -b >/dev/null 2>&1; then
      green "  simulator ready"
    else
      red "  simulator did not report ready — continuing, the launch may still succeed"
    fi

    bold "==> iPhone tests on $IOS_SIM (shared-package guard)"
    xcodebuild test \
      -project ios/BatonMobile.xcodeproj \
      -scheme BatonMobile \
      -destination "id=$IOS_SIM_UDID" \
      -only-testing:BatonMobileTests \
      -derivedDataPath "${DERIVED}-ios" \
      -resultBundlePath "$IOS_RESULT_BUNDLE" >"$IOS_LOG" 2>&1
    ios_status=$?
    ios_what="iPhone tests"
  else
    bold "==> Building iPhone app (no simulator installed)"
    xcodebuild build \
      -project ios/BatonMobile.xcodeproj \
      -scheme BatonMobile \
      -destination 'generic/platform=iOS' \
      -derivedDataPath "${DERIVED}-ios" \
      CODE_SIGNING_ALLOWED=NO >"$IOS_LOG" 2>&1
    ios_status=$?
    ios_what="iPhone build"
  fi
  set -e

  if [ "$ios_status" -eq 0 ]; then
    # The result bundle, not the log. This was `grep -hoE 'Executed [0-9]+ tests?' | tail -1`
    # — the XCTest rollup, which cannot see a swift-testing test and so reported 154 for a
    # run of 157. See `bundle_counts` above for the measurement and why it matters more
    # than three tests. (TBX-5236)
    ios_counts="$(bundle_counts "$IOS_RESULT_BUNDLE")"
    ios_failed_n=""
    if [ -n "$ios_counts" ]; then
      ios_n="$(printf '%s\n' "$ios_counts" | awk '{ print $1 }')"
      ios_failed_n="$(printf '%s\n' "$ios_counts" | awk '{ print $3 }')"
      ios_count="$(printf '%s\n' "$ios_counts" \
        | awk '{ printf "%s tests: %s passed, %s failed, %s skipped", $1, $2, $3, $4 }')"
    else
      # Degraded but still counting both reporters. Kept because a scraped count beats
      # none (an older xcresulttool, a run killed before the bundle was written), and
      # because the build-only branch above has no bundle at all and never will.
      ios_n="$(log_test_total "$IOS_LOG")"
      ios_count=""
      if [ -n "$ios_n" ]; then ios_count="$ios_n tests (scraped from the log — no result bundle)"; fi
    fi
    # Zero tests is not a pass — but only when this was a *test* run. The build-only
    # branch above (no simulator installed) legitimately executes none, and it is the one
    # case here where an empty run is expected rather than suspicious. The guard is
    # stronger now that it counts the whole population rather than the XCTest half of it.
    if [ "$ios_what" = "iPhone tests" ] && [ "${ios_n:-0}" -eq 0 ] && empty_run_is_failure; then
      red "✗ ${ios_what} executed NO tests — exit 0, and nothing was proved"
      red "  The build succeeded and the filter matched nothing: check -only-testing:BatonMobileTests"
      red "  still names a target that exists. ALLOW_NO_TESTS=1 to accept an empty run."
      red "  Full log: $IOS_LOG"
      exit 1
    fi
    # And a bundle recording failures overrides a zero exit, exactly as the Mac summary
    # below does: that is the direction that actually ships a broken build, because nobody
    # re-reads a log that says everything passed.
    if [ -n "$ios_failed_n" ] && [ "$ios_failed_n" -gt 0 ]; then
      red "✗ ${ios_what}: xcodebuild exited 0 but the result bundle records $ios_failed_n failure(s) — trusting the bundle"
      red "  Full log: $IOS_LOG"
      red "  Result bundle: $IOS_RESULT_BUNDLE"
      exit 1
    fi
    green "  ${ios_what} pass${ios_count:+ — $ios_count}"
  else
    # A launch failure and a test failure are not the same news, and until now they read
    # identically: "the other app is broken", which is a claim about the code. When
    # SpringBoard refuses to start the app there is no finding at all — nothing ran.
    # Saying so is the difference between "investigate the diff" and "the machine was
    # busy", at the moment that distinction is most expensive to work out by hand.
    #
    # Note this does NOT retry, and it still fails the gate. Whether an environmental
    # launch failure should ever be retried is a live question (it changes what a red gate
    # means), and prevention above is the half that does not need it answered.
    if grep -qE 'FBSOpenApplicationServiceErrorDomain|failed preflight checks|Simulator device failed to launch|Unable to boot device' "$IOS_LOG"; then
      red "✗ ${ios_what} could not LAUNCH — this is environmental, not a code finding"
      red "  The simulator refused to start the app, so no test result exists either way."
      grep -E 'FBSOpenApplicationServiceErrorDomain|failed preflight checks|Simulator device failed to launch|Unable to boot device' "$IOS_LOG" \
        | sed 's/^/    /' | head -5 >&2 || true
      red "  Simulator: $IOS_SIM ($IOS_SIM_UDID). Current state:"
      xcrun simctl list devices | grep -F "$IOS_SIM_UDID" | sed 's/^/    /' >&2 || true
      red "  The gate still fails. Re-run once the device has settled — do not paper over a"
      red "  repeat: a launch that keeps failing on a settled simulator is a real finding."
    else
      red "✗ ${ios_what} FAILED — the other app is broken"
      diagnose_build_failure "$IOS_LOG"
    fi
    red "  Full log: $IOS_LOG"
    # Only when the run got far enough to write one — the build-only branch never does,
    # and naming a path that does not exist is its own small lie.
    if [ -d "$IOS_RESULT_BUNDLE" ]; then
      red "  Result bundle: $IOS_RESULT_BUNDLE"
    fi
    exit "$ios_status"
  fi
  # --- Watch build -----------------------------------------------------------
  #
  # The third app, and the one nobody remembers. It is PARKED, not shipping — see
  # docs/watch-app-parked.md — and this build is precisely what makes parking it safe.
  #
  # It links the same packages and had been failing to compile since the offline-envelope
  # fallback landed: a call to a `#if !os(watchOS)` type that was not itself guarded, which
  # went unnoticed for exactly as long as nothing built it. The engine merge then broke it a
  # second, independent way.
  #
  # It is also what keeps `EngineDeckUnavailable.swift` honest: the watch stand-in for
  # `EngineDeckBridge` must keep pace with the real one, and this build is the only thing
  # that enforces that.
  WATCH_SIM="$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import sys, json
try:
    devices = json.load(sys.stdin)['devices']
except Exception:
    sys.exit()
for runtime, entries in devices.items():
    if 'watchOS' in runtime and entries:
        print(entries[0]['udid'])
        sys.exit()
" 2>/dev/null)"

  if [ -n "$WATCH_SIM" ]; then
    bold "==> Building Watch app"
    # Generate the Watch project the same way the Mac and iPhone ones are generated
    # above. The .xcodeproj is gitignored, so on a fresh clone it does not exist and
    # this step failed with "watch/BatonWatch.xcodeproj does not exist" — invisible on
    # a machine where an earlier run had left one behind.
    ( cd watch && xcodegen generate >/dev/null )
    WATCH_LOG="$(mktemp -t baton-watch-build.XXXXXX).log"
    set +e
    xcodebuild build \
      -project watch/BatonWatch.xcodeproj \
      -scheme BatonWatch \
      -destination "id=$WATCH_SIM" \
      -derivedDataPath "${DERIVED}-watch" \
      CODE_SIGNING_ALLOWED=NO >"$WATCH_LOG" 2>&1
    watch_status=$?
    set -e
    if [ "$watch_status" -eq 0 ]; then
      green "  Watch builds"
    else
      red "✗ WATCH BUILD FAILED — shared-package change broke the third app"
      diagnose_build_failure "$WATCH_LOG"
      red "  Full log: $WATCH_LOG"
      exit "$watch_status"
    fi
  else
    bold "==> Skipping Watch build (no watchOS simulator installed)"
  fi
else
  bold "==> Skipping iPhone and Watch checks (SKIP_IOS set)"
fi

# --- The gateway ------------------------------------------------------------------
#
# The fourth thing this repo ships, and until now the only one nothing built. That is
# precisely the hole the Watch app fell through twice — it silently stopped compiling and
# nobody noticed, because no gate touched it — and the Watch is *parked*, while the gateway
# is load-bearing for phone sync. It also shares `Packages/`, so a change there can break it
# exactly the way the audio-engine merge broke the iPhone.
#
# Fast: a SwiftPM build and its unit tests, no simulator. Skipped with the iPhone and Watch
# under SKIP_IOS, since that flag means "the quick local loop".
if [ -z "${SKIP_IOS:-}" ]; then
  bold "==> Gateway build + tests"
  GATEWAY_LOG="$(mktemp -t baton-gateway.XXXXXX).log"
  set +e
  ( cd gateway && swift test ) >"$GATEWAY_LOG" 2>&1
  gateway_status=$?
  set -e
  if [ "$gateway_status" -eq 0 ]; then
    # Both reporters, summed. `swift test` writes no result bundle, so the log is all there
    # is — but the log carries two rollups and this line used to read only the XCTest one.
    # The gateway has no `@Test` tests today; the whole point is that the number will move
    # on the day it gets one, rather than silently staying put. (TBX-5236)
    gateway_n="$(log_test_total "$GATEWAY_LOG")"
    green "  gateway builds and its tests pass${gateway_n:+ — $gateway_n tests}"
  else
    red "✗ GATEWAY FAILED — the home gateway no longer builds or its tests fail"
    grep -E 'error:|failed' "$GATEWAY_LOG" | sed 's/^/    /' | head -20 >&2 || true
    red "  Full log: $GATEWAY_LOG"
    exit "$gateway_status"
  fi

  # The gateway is the one part of Baton meant to run on Linux, and until 2026-08-29 it could
  # not: BatonAgentKit pulled in the whole AVFoundation audio engine for three read-only
  # properties. Nothing noticed for a long time, because the only thing that ever built the
  # gateway was this script, on macOS, where the Apple branch of every `#if` compiles fine.
  #
  # So building it for Linux is the check. It is not about Docker — it is the only way to
  # assert that the agent layer has stayed free of Apple-only dependencies. Skipped when
  # Docker is absent, because an unavailable builder is *not measurable* rather than broken:
  # the same judgement the conversation eval makes about an unreachable model host.
  if [ "${SKIP_LINUX_GATEWAY:-0}" != "1" ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    bold "==> Gateway builds for Linux (agent-layer platform guard)"
    LINUX_LOG="$(mktemp -t baton-gateway-linux.XXXXXX).log"
    set +e
    docker build -f gateway/deploy/Dockerfile -t baton-gateway:gate . >"$LINUX_LOG" 2>&1
    linux_status=$?
    set -e
    if [ "$linux_status" -eq 0 ]; then
      green "  gateway builds for Linux"
    else
      red "✗ GATEWAY NO LONGER BUILDS FOR LINUX"
      red "  Something in BatonAgentKit (or below it) now needs an Apple-only framework."
      red "  The usual cause is a new import that reaches BatonPlaybackKit; see RemotePlayerContext."
      grep -E "error:|no such module" "$LINUX_LOG" | sed 's/^/    /' | head -15 >&2 || true
      red "  Full log: $LINUX_LOG"
      exit "$linux_status"
    fi
  else
    yellow "  Linux gateway build skipped (no usable docker) — the agent layer's platform boundary is unverified"
  fi
fi

bold "==> Running tests ($SCHEME)"
# Sibling of the log, so the two are findable together and a fresh mktemp name each run
# means xcodebuild never refuses an existing bundle path.
RESULT_BUNDLE="${LOG%.log}.xcresult"
set +e
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "$RESULT_BUNDLE" \
  "$@" >"$LOG" 2>&1
status=$?
set -e

# --- The summary, from the result bundle -----------------------------------
#
# The authority is `xcresulttool get test-results summary`, not the log. CLAUDE.md already
# says to read the bundle rather than the log when checking a run by hand; the gate has no
# business holding itself to a lower standard, and the log has now been wrong in both
# directions. On 2026-08-12 it announced "Executed 777 tests across 4 bundles, with 0
# failures" with an empty "Failing cases:" list for a run the bundle recorded as 1400
# passed / 1 failed / 5 skipped — the conversation eval took the runner down with it, so
# the per-bundle rollup lines the scrape below depends on were simply never printed.
# Anyone reading that log would have concluded the run was healthy and merely truncated.
#
# The bundle also decides the verdict, not just the wording: a run whose bundle records
# failures is a failed run even if xcodebuild exited 0.
bundle_summary=""
bundle_failures=""
bundle_failed_count=""
bundle_total=""
if [ -d "$RESULT_BUNDLE" ]; then
  bundle_json="$(xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --compact 2>/dev/null || true)"
  if [ -n "$bundle_json" ]; then
    bundle_summary="$(printf '%s' "$bundle_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print("%d tests: %d passed, %d failed, %d skipped (%s)" % (
    d.get("totalTestCount", 0), d.get("passedTests", 0),
    d.get("failedTests", 0), d.get("skippedTests", 0), d.get("result", "?")))
' 2>/dev/null || true)"
    bundle_failed_count="$(printf '%s' "$bundle_json" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("failedTests", 0))
except Exception:
    sys.exit(1)
' 2>/dev/null || true)"
    bundle_total="$(printf '%s' "$bundle_json" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("totalTestCount", 0))
except Exception:
    sys.exit(1)
' 2>/dev/null || true)"
    bundle_failures="$(printf '%s' "$bundle_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
failures = d.get("testFailures") or []
if isinstance(failures, dict):        # the schema types this singular; runs emit a list
    failures = [failures]
for f in failures[:25]:
    text = (f.get("failureText") or "").strip().splitlines()
    print("%s/%s%s" % (f.get("targetName", "?"), f.get("testName", "?"),
                       " — " + text[0] if text else ""))
' 2>/dev/null || true)"
  fi
fi

# Fallback for when the bundle is missing or unreadable (an older xcresulttool, a run
# killed before it was written). Kept because a degraded summary beats none.
#
# The per-bundle summing lives in `xctest_log_counts` above, where the iPhone and gateway
# stages can reach it too — and where a fixture can be planted at it. Its own history is
# recorded there: `tail -2` reported a green 790-test run as "Executed 4 tests" when the
# last suite to print was a small one, and "take the largest count" then dropped two
# hundred tests once the scheme gained the package test bundles.
xctest_counts="$(xctest_log_counts "$LOG")"
xctest_summary=""
if [ -n "$xctest_counts" ]; then
  xctest_summary="$(printf '%s\n' "$xctest_counts" \
    | awk '{ printf "Executed %s tests across %s bundles, with %s failures", $1, $2, $3 }')"
fi
# `|| true` is load-bearing. Under `set -euo pipefail` a grep that matches nothing fails
# the pipeline, and the assignment takes that status — so on a run with no test lines at
# all (a compile error is the common one) the script died right here, exit 1, having
# printed not one word about why. That is worse than a wrong summary: a build failure
# produced no diagnostics whatsoever, and the caller saw a bare nonzero exit.
swift_testing_summary="$(grep -hoE 'Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)' "$LOG" | tail -1 || true)"
scraped_summary="$(printf '%s %s' "$xctest_summary" "$swift_testing_summary")"

# A bundle recording zero tests needs saying in words: "0 tests: 0 passed, 0 failed" is
# true and useless, because it reads like an empty suite rather than like a run that never
# happened. There are two ways to get here and they are different news, so `status` — which
# is xcodebuild's own exit code, before any override below — decides which one to say. The
# old text claimed the build "did not get that far" in both cases, which was a guess that
# happened to be right only for the compile failure.
if [ -n "$bundle_summary" ] && [ "${bundle_total:-0}" != "0" ]; then
  summary="$bundle_summary"
elif [ -n "$bundle_summary" ] && [ "$status" -ne 0 ]; then
  # "the build did not get that far" was true and unhelpful: it says where the run
  # stopped, never why. The headline names the cause from the log itself. (TBX-5139)
  summary="no tests ran — $(diagnose_headline "$LOG")"
elif [ -n "$bundle_summary" ]; then
  summary="no tests ran — the build succeeded and nothing matched"
elif [ "$status" -ne 0 ] && [ -z "${scraped_summary//[[:space:]]/}" ]; then
  # No result bundle AND nothing to scrape — the run died early enough that the old text
  # was a bare " (scraped from the log — no result bundle)", which named neither a count
  # nor a cause.
  summary="no tests ran — $(diagnose_headline "$LOG")"
else
  summary="${scraped_summary} (scraped from the log — no result bundle)"
fi

# A bundle recording failures overrides a zero exit. This is the direction that actually
# ships a broken build: nobody re-reads a log that says everything passed.
if [ "$status" -eq 0 ] && [ -n "$bundle_failed_count" ] && [ "$bundle_failed_count" -gt 0 ]; then
  red "  xcodebuild exited 0 but the result bundle records $bundle_failed_count failure(s) — trusting the bundle"
  status=1
fi

# And a bundle recording *no tests at all* overrides a zero exit too — see
# `empty_run_is_failure`. Kept separate from the failure-count check above because the two
# say different things: that one is "the tests ran and some failed", this one is "the tests
# never ran". `empty_run` is remembered so the diagnosis below does not mistake it for a
# compile failure, which is the other way to reach a bundle with zero tests.
empty_run=""
if [ "$status" -eq 0 ] && [ -n "$bundle_summary" ] && [ "${bundle_total:-0}" = "0" ] && empty_run_is_failure; then
  red "  xcodebuild exited 0 but the result bundle records no tests at all — trusting the bundle"
  empty_run=1
  status=1
fi

# An externally-terminated run is not a test failure, and must not be reported as one.
#
# `RunnerExitDiagnostic` prints this marker when the host process leaves while a test is still
# running, with a backtrace naming the caller. Four times so far it has named a menu-bar click
# or an Apple Event quit — a person closing what looked like a spare copy of Baton. The run then
# failed pointing at whichever test was in flight, which passed in isolation every time, and the
# blame landed on innocent code. The host now hides itself from the Dock and menu bar during a
# run (see `RunnerExitDiagnosticBootstrap`), so this should be rare; when it still happens, say
# what happened rather than naming a test. (TBX-3862)
if [ "$status" -ne 0 ] && grep -q "BATON-DIAG: the test host is exiting while" "$LOG" 2>/dev/null; then
  red "✗ RUN INTERRUPTED — the test host was terminated from outside while a test was running."
  red "  This is not a test failure and the test named below is not implicated."
  grep -A2 "BATON-DIAG: the test host is exiting while" "$LOG" | sed 's/^/    /' >&2
  red "  Full log: $LOG"
  exit "$status"
fi

if [ "$status" -eq 0 ]; then
  green "✓ TESTS PASSED — ${summary:-see $LOG}"
else
  red "✗ TESTS FAILED (exit $status) — ${summary:-see $LOG}"
  if [ -n "$bundle_failures" ]; then
    red "  Failing cases:"
    printf '%s\n' "$bundle_failures" | sed 's/^/    /' >&2
  elif [ -n "$empty_run" ]; then
    # The build succeeded and nothing matched, so there are neither failing cases nor
    # compiler diagnostics to print. This branch must stand *before* the compile-error one
    # below: both are "the bundle holds zero tests", and printing an empty "Compile errors:"
    # for a build that compiled fine is the same species of misleading output as the green
    # tick this whole change is about.
    red "  Nothing ran, so nothing was proved. The build succeeded — this is a filter that"
    red "  matched no tests, or a scheme with no test targets."
    if [ "$#" -gt 0 ]; then
      red "  Arguments forwarded to xcodebuild: $*"
    else
      red "  No extra arguments were passed, so check the scheme's test targets."
    fi
    red "  ALLOW_NO_TESTS=1 to accept an empty run."
  else
    # Two ways to get here and one right answer for both. Either the bundle holds zero
    # tests (the build stopped before them) or there is no bundle at all (it stopped
    # earlier still) — and in both cases the useful output is whatever the build system
    # said, which is what `diagnose_build_failure` reads.
    #
    # These were two arms with two hard-coded headers: "Compile errors:" and "Failing
    # cases:". Each named a cause by position in an if-chain rather than by evidence, so
    # a codesign failure printed "Compile errors:" above nothing at all. (TBX-5139) The
    # routine classifies from the log and refuses to print a header it cannot fill.
    diagnose_build_failure "$LOG"
  fi
  # --- Keep the evidence -----------------------------------------------------
  #
  # `$LOG` and `$RESULT_BUNDLE` live in `$TMPDIR`, which macOS reaps by age. That is not a
  # theoretical loss: when the test runner died mid-suite on 2026-08-12 both were already
  # gone by the time anyone looked, and what one surviving log would have answered instead
  # cost four repro attempts, a diagnostic harness, and a day. A failing run is exactly when
  # the evidence has to outlive the temp directory.
  #
  # Failures only, on purpose: a green run's log is noise, and copying every result bundle
  # would quietly put gigabytes somewhere nobody empties.
  keep_dir="$HOME/Library/Logs/Baton/gate-failures/$(date +%Y-%m-%d_%H-%M-%S)"
  if mkdir -p "$keep_dir" 2>/dev/null; then
    cp "$LOG" "$keep_dir/xcodebuild.log" 2>/dev/null || true
    [ -d "$RESULT_BUNDLE" ] && cp -R "$RESULT_BUNDLE" "$keep_dir/results.xcresult" 2>/dev/null || true
    # Bounded, so this can never become the thing that fills the disk. Ten is enough to
    # cover a bad afternoon and small enough to stay ignorable.
    ls -dt "$HOME/Library/Logs/Baton/gate-failures"/* 2>/dev/null | tail -n +11 | while read -r old; do
      rm -rf "$old"
    done
    red "  Kept: $keep_dir"
    red "  (the copies below are in \$TMPDIR and will be reaped — read the kept ones)"
  fi
  red "  Full log: $LOG"
  red "  Result bundle: $RESULT_BUNDLE"
fi
exit "$status"
