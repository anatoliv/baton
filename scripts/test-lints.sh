#!/bin/bash
#
# The source lints in `scripts/test.sh` can actually fail. (TBX-5132)
#
# WHY THIS EXISTS. Both lints were written as `grep … | grep -q .` with the violation in
# the `then` branch. Under the `set -o pipefail` at the top of that file, that shape fails
# **open**: `grep -q` exits at its first match, the producer dies on the closed pipe with
# SIGPIPE, and pipefail reports 141, which `if` reads as "nothing found".
#
# It depends on whether the producer's output fits the pipe buffer before `grep -q` leaves,
# so a couple of violations pass through and the lint appears to work. It breaks precisely
# when there is the most to find — and one of the two is a credential lint, so it could
# pass while a full URL with Subsonic auth in its query string was being logged.
#
# Watching a guard fail on planted input is the only thing that proves it can. No Xcode, no
# network, about a second.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Run the real gate's lint block against a planted tree, by pointing SRC at it. Everything
# after the lints is skipped: LINT_ONLY exits as soon as the verdict is known.
run_lints_over() {   # $1 = directory to lint
  # Drives the REAL block in scripts/test.sh, not a copy of it. A guard that reimplements
  # its subject can pass while the subject is broken, which is the entire lesson here.
  BATON_LINT_SRC="$1" LINT_ONLY=1 ./scripts/test.sh >/dev/null 2>&1
}

expect() {   # $1 = "clean"|"dirty", $2 = dir, $3 = name
  run_lints_over "$2"; local rc=$?
  if [ "$1" = clean ]; then
    [ "$rc" -eq 0 ] && ok "$3" || bad "$3 (expected pass, got $rc)"
  else
    [ "$rc" -ne 0 ] && ok "$3" || bad "$3 (expected FAIL, lint passed — fail-open)"
  fi
}

# 1. A tree with nothing wrong must pass, or every later result is meaningless.
mkdir -p "$WORK/clean"
printf 'import OSLog\nlet log = Logger(subsystem: "io.tonebox.baton", category: "x")\n' > "$WORK/clean/Fine.swift"
expect clean "$WORK/clean" "a clean tree passes"

# 2. ONE violation of each — the case the old shape handled, so this is the weak test.
mkdir -p "$WORK/one-url" "$WORK/one-subsystem"
printf 'log.error("url \\(u.absoluteString)")\n' > "$WORK/one-url/Leak.swift"
expect dirty "$WORK/one-url" "one logged URL is caught"
printf 'let log = Logger(subsystem: "com.example.other", category: "x")\n' > "$WORK/one-subsystem/Sub.swift"
expect dirty "$WORK/one-subsystem" "one foreign Logger subsystem is caught"

# 3. MANY violations — the case that actually failed. The old form returned 141 here and
#    reported success, so this is the assertion with teeth.
mkdir -p "$WORK/many-url" "$WORK/many-subsystem"
for i in $(seq 1 400); do
  { echo "import OSLog"
    for j in $(seq 1 20); do echo "func leak${i}_${j}() { log.error(\"url \\(r.url!.absoluteString)\") }"; done
  } > "$WORK/many-url/Leak$i.swift"
  { for j in $(seq 1 20); do echo "let log${i}_${j} = Logger(subsystem: \"com.example.other\", category: \"c\")"; done
  } > "$WORK/many-subsystem/Sub$i.swift"
done
expect dirty "$WORK/many-url" "8000 logged URLs are caught (the fail-open case)"
expect dirty "$WORK/many-subsystem" "8000 foreign subsystems are caught (the fail-open case)"

# 4. W-19, the accessibility lint. It used to be scoped to a list of nine primary-path file
#    names, so it could go blocking before the rest of the tree was clean — which meant a
#    planted violation had to carry one of those names to be caught, and 55 real ones sat
#    outside it undetected (TBX-5327). Every file is in scope now, so these plant the same
#    violations under names the old allowlist would have ignored.
mkdir -p "$WORK/icon-multiline" "$WORK/icon-oneline" "$WORK/icon-any-name" "$WORK/icon-labelled" "$WORK/icon-ios-shaped"
cat > "$WORK/icon-multiline/NowPlayingBar.swift" <<'SWIFT'
struct Bar: View {
    var body: some View {
        Button { player.next() } label: {
            Image(systemName: "forward.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Next")
    }
}
SWIFT
expect dirty "$WORK/icon-multiline" "an unlabelled icon Button is caught (help alone is not a label)"

printf 'Button { copy(t) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)\n' \
  > "$WORK/icon-oneline/BatonSettingsView.swift"
expect dirty "$WORK/icon-oneline" "the one-line form is caught too"

mkdir -p "$WORK/icon-action"
cat > "$WORK/icon-action/MusicDownloadsView.swift" <<'SWIFT'
struct Row: View {
    var body: some View {
        Button(action: onPlay) {
            Image(systemName: "play.fill")
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
SWIFT
expect dirty "$WORK/icon-action" "the Button(action:) form is caught too"

# The old allowlist would have passed this silently because the name isn't one of the nine.
# There is no allowlist now, so any file name is in scope.
cp "$WORK/icon-multiline/NowPlayingBar.swift" "$WORK/icon-any-name/SomeOtherPane.swift"
expect dirty "$WORK/icon-any-name" "the same violation under a name outside the old allowlist is now flagged too"

# The same algorithm over an iPhone-shaped file, proving the lint isn't Mac-only: before
# this branch, `SRC` defaulted to app/Sources/Baton alone and ios/Sources was never scanned
# at all, allowlist or not.
cat > "$WORK/icon-ios-shaped/LibraryView.swift" <<'SWIFT'
struct LibraryView: View {
    var body: some View {
        Button { newName = ""; showsNew = true } label: {
            Image(systemName: "plus")
        }
        .disabled(model.isDemoMode)
    }
}
SWIFT
expect dirty "$WORK/icon-ios-shaped" "an iPhone-shaped file is scanned the same way"

# A label eighteen lines below the closure still counts: the chain is read by brace
# balance, not a fixed window. This is the shape a windowed version got wrong.
cat > "$WORK/icon-labelled/NowPlayingBar.swift" <<'SWIFT'
struct Bar: View {
    var body: some View {
        Button { showingQueue.toggle() } label: {
            Image(systemName: "list.bullet")
                .overlay(alignment: .topTrailing) {
                    if upcomingCount > 0 {
                        Text("\(upcomingCount)")
                            .padding(.horizontal, 3)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 9, y: -7)
                    }
                }
        }
        .buttonStyle(.plain)
        .help("Queue")
        .accessibilityLabel("Queue")
    }
}
SWIFT
expect clean "$WORK/icon-labelled" "a label below a multi-line overlay is found"

# 5. The real tree must be clean, in both apps now that neither is scoped out, which is
#    also a check that the patterns still match the code's shape rather than having rotted
#    into matching nothing.
expect clean "app/Sources/Baton" "the real Mac source tree is clean"
expect clean "ios/Sources" "the real iPhone source tree is clean"

# 6. With BATON_LINT_SRC unset, the real gate scans both apps by default — the actual shape
#    a merge sees, not a single directory standing in for it.
if BATON_LINT_SRC= LINT_ONLY=1 ./scripts/test.sh >/dev/null 2>&1; then
  ok "the default (unscoped) run covers both apps and is clean"
else
  bad "the default (unscoped) run covers both apps and is clean (expected pass, got nonzero)"
fi

# 6. W-20, the Linux-import lint (TBX-5323). It drives the SAME real block via a second
# override, BATON_IMPORT_LINT_SRC, so a planted tree here does not also feed the W-16/W-18/
# W-19 lints above (those still read the real app/Sources/Baton, which is clean per case 5).
run_import_lint_over() {   # $1 = directory to lint
  BATON_IMPORT_LINT_SRC="$1" LINT_ONLY=1 ./scripts/test.sh >/dev/null 2>&1
}
expect_import() {   # $1 = "clean"|"dirty", $2 = dir, $3 = name
  run_import_lint_over "$2"; local rc=$?
  if [ "$1" = clean ]; then
    [ "$rc" -eq 0 ] && ok "$3" || bad "$3 (expected pass, got $rc)"
  else
    [ "$rc" -ne 0 ] && ok "$3" || bad "$3 (expected FAIL, lint passed)"
  fi
}

# The exact defect that shipped: BatonStorage.swift wrote `import OSLog` directly instead of
# going through PlatformCompat.swift. Same filename, so a fix that only checks the message
# rather than the file it names would not be caught here either.
mkdir -p "$WORK/import-bare-oslog"
printf 'import OSLog\nimport Foundation\n\nstruct BatonStorage {}\n' > "$WORK/import-bare-oslog/BatonStorage.swift"
expect_import dirty "$WORK/import-bare-oslog" "a bare import OSLog is caught (the BatonStorage.swift defect)"

mkdir -p "$WORK/import-bare-cryptokit"
printf 'import CryptoKit\nimport Foundation\n' > "$WORK/import-bare-cryptokit/Hash.swift"
expect_import dirty "$WORK/import-bare-cryptokit" "a bare import CryptoKit is caught"

# A guarded import must pass: this is the PlatformCompat.swift shape.
mkdir -p "$WORK/import-guarded"
cat > "$WORK/import-guarded/Compat.swift" <<'SWIFT'
#if canImport(OSLog)
import OSLog
#else
import Foundation
#endif
SWIFT
expect_import clean "$WORK/import-guarded" "a guarded import behind #if canImport is not flagged"

# Observation ships on Linux Swift 6 (swift:6.0-jammy), so it must NOT be in the forbidden
# set even though it sits beside SwiftUI/Combine in most people's heads. The card that filed
# this lint called this out explicitly as the mistake to not make.
mkdir -p "$WORK/import-observation"
printf 'import Observation\nimport Foundation\n' > "$WORK/import-observation/Watched.swift"
expect_import clean "$WORK/import-observation" "a bare import Observation is NOT flagged (it ships on Linux Swift 6)"

# The real gateway dependency graph must be clean today, and stay the check that catches the
# next drift before deploy.sh does.
for real_dir in \
  Packages/BatonAgentKit/Sources \
  Packages/BatonSubsonicKit/Sources \
  Packages/BatonSubsonicModels/Sources \
  Packages/BatonMCPProtocol/Sources \
  gateway/Sources
do
  expect_import clean "$real_dir" "the real $real_dir is clean of unguarded Linux-missing imports"
done

# 7. W-21, the prose-dash lint (TBX-5348). Same pattern again: a third override,
# BATON_DASH_LINT_SRC, points the REAL block at a planted tree. The cases below are the
# shapes the grep this replaced could not see, which is the whole reason it is a lexer.
#
# The dashes themselves are built with printf rather than typed, so this file stays free of
# the characters it exists to catch and nobody later "tidies" a fixture into passing.
EM="$(printf '\xe2\x80\x94')"
EN="$(printf '\xe2\x80\x93')"
DASH_ALLOWLIST="scripts/lint-prose-dashes-allowlist.txt"

run_dash_lint_over() {   # $1 = directory to lint, $2 = allowlist file ("" = none)
  BATON_DASH_LINT_SRC="$1" BATON_DASH_LINT_ALLOWLIST="${2:-/dev/null}" LINT_ONLY=1 \
    ./scripts/test.sh >/dev/null 2>&1
}
expect_dash() {   # $1 = "clean"|"dirty", $2 = dir, $3 = name, $4 = optional allowlist
  run_dash_lint_over "$2" "${4:-}"; local rc=$?
  if [ "$1" = clean ]; then
    [ "$rc" -eq 0 ] && ok "$3" || bad "$3 (expected pass, got $rc)"
  else
    [ "$rc" -ne 0 ] && ok "$3" || bad "$3 (expected FAIL, lint passed)"
  fi
}

# The plain case: one em dash in one ordinary string.
mkdir -p "$WORK/dash-plain"
echo "let t = Text(\"Nothing is playing $EM start a track first.\")" > "$WORK/dash-plain/Pane.swift"
expect_dash dirty "$WORK/dash-plain" "an em dash in a plain string literal is caught"

# The one that shipped: a backslash-continued multi-line string, where the dash and the
# opening quote sit on different source lines. A line grep for a quoted dash called this
# file clean, which is how the Settings, Remote linking hint survived the 0.19.0 pass.
mkdir -p "$WORK/dash-continued"
cat > "$WORK/dash-continued/BatonRemotePane.swift" <<SWIFT
let body = """
Message your bot from the chat you want to control \\
Baton with $EM on either service. Until you do it ignores everyone.
"""
SWIFT
expect_dash dirty "$WORK/dash-continued" "a backslash-continued multi-line string is caught (the one the grep missed)"

# An en dash counts too, and a raw string has its own delimiter rules to get right.
mkdir -p "$WORK/dash-raw"
echo "let s = #\"Set a 1${EN}5 star rating.\"#" > "$WORK/dash-raw/Rating.swift"
expect_dash dirty "$WORK/dash-raw" "an en dash inside a raw string literal is caught"

# A string nested inside an interpolation inside another string: the case a scanner without
# a stack loses, and from there it reads code as text and text as code.
mkdir -p "$WORK/dash-nested"
cat > "$WORK/dash-nested/Nested.swift" <<SWIFT
let s = "outer \\(inner.map { "inner $EM dash" } ?? "none") tail"
SWIFT
expect_dash dirty "$WORK/dash-nested" "a dash inside a string nested in an interpolation is caught"

# Comments are not copy. Flagging them would make the lint noisy in files whose strings are
# all fine, and a noisy lint gets bypassed and then guards nothing.
mkdir -p "$WORK/dash-comment"
cat > "$WORK/dash-comment/Commented.swift" <<SWIFT
/// The artist banner $EM a blurred backdrop, per the design note.
// Another one $EM still a comment.
/* And a block $EM also a comment. */
let fine = "No dash in here at all."
SWIFT
expect_dash clean "$WORK/dash-comment" "an em dash in a comment is NOT flagged"

# An escaped quote must not end the string early, or everything after it reads as code and
# the next real dash goes unseen.
mkdir -p "$WORK/dash-escaped-quote"
cat > "$WORK/dash-escaped-quote/Escaped.swift" <<SWIFT
let a = "he said \\"hello\\" and left"
let b = "then this one $EM which must still be found"
SWIFT
expect_dash dirty "$WORK/dash-escaped-quote" "an escaped quote does not hide a later dash"

# The allowlist has to actually silence an entry, keyed on the path plus the line text.
mkdir -p "$WORK/dash-allowed"
ALLOWED_LINE="Text(album.duration.map { fmt(\$0) } ?? \"$EM\")"
echo "$ALLOWED_LINE" > "$WORK/dash-allowed/Row.swift"
expect_dash dirty "$WORK/dash-allowed" "the deliberate no-value glyph is flagged when nothing allows it"
printf '%s\t%s\n' "$WORK/dash-allowed/Row.swift" "$ALLOWED_LINE" > "$WORK/dash-allowed.txt"
expect_dash clean "$WORK/dash-allowed" "an allowlisted line passes" "$WORK/dash-allowed.txt"
# ...and only that line. The exemption is for this text, not for this file.
echo "let hint = \"Off by default $EM it needs an API key.\"" >> "$WORK/dash-allowed/Row.swift"
expect_dash dirty "$WORK/dash-allowed" "an allowlisted file is not a blanket exemption" "$WORK/dash-allowed.txt"

# The real trees must be clean against the real allowlist, which is also the check that the
# lexer still matches the code's shape rather than having rotted into matching nothing.
expect_dash clean "app/Sources" "the real Mac source tree is free of prose dashes" "$DASH_ALLOWLIST"
expect_dash clean "ios/Sources" "the real iPhone source tree is free of prose dashes" "$DASH_ALLOWLIST"
expect_dash clean "Shared" "the real Shared tree is free of prose dashes" "$DASH_ALLOWLIST"

# TBX-5362 widened the default roots from the two apps to also cover Packages, gateway and
# watch/Sources: the lexer never looked past app/Sources and ios/Sources, so the Telegram and
# Discord bot replies in Packages/BatonAgentKit (a user reads every one of those in a chat
# window) and the gateway's own replies were unguarded. Same two checks as above, over the
# three roots that joined the gate.
expect_dash clean "Packages" "the real Packages tree is free of prose dashes" "$DASH_ALLOWLIST"
expect_dash clean "gateway" "the real gateway tree is free of prose dashes" "$DASH_ALLOWLIST"
expect_dash clean "watch/Sources" "the real watch/Sources tree is free of prose dashes" "$DASH_ALLOWLIST"

# A planted violation under one of the new roots' own shape (a SwiftPM package: Sources/
# beside Tests/, which is what Packages/ and gateway/ actually are) has to be caught, or
# widening the default roots did nothing.
mkdir -p "$WORK/dash-package/Sources/BatonExampleKit" "$WORK/dash-package/Tests/BatonExampleKitTests"
cat > "$WORK/dash-package/Sources/BatonExampleKit/ExampleReply.swift" <<SWIFT
func reply() -> String { "Linked $EM send \`help\` for the commands." }
SWIFT
expect_dash dirty "$WORK/dash-package" "a dash in a package's Sources is caught (the new-roots shape)"

# ...but the SAME package's Tests directory must NOT be, which is the whole reason widening
# to whole packages (rather than enumerating every Sources/ by hand) was safe: TBX-5362 left
# test fixtures alone, same call AppStoreMetadataTests already made for its own counting, and
# a package root always carries Tests/ beside Sources/.
rm "$WORK/dash-package/Sources/BatonExampleKit/ExampleReply.swift"
cat > "$WORK/dash-package/Tests/BatonExampleKitTests/ExampleReplyTests.swift" <<SWIFT
func testReply() { XCTAssertEqual(reply(), "expected $EM not actual") }
SWIFT
expect_dash clean "$WORK/dash-package" "a dash inside a package's Tests directory is NOT flagged (fixtures stay)"

# With BATON_DASH_LINT_SRC unset the gate scans all six roots with the real allowlist, which
# is the shape a merge actually sees.
if LINT_ONLY=1 ./scripts/test.sh >/dev/null 2>&1; then
  ok "the default (unscoped) dash lint covers all six roots and is clean"
else
  bad "the default (unscoped) dash lint covers all six roots and is clean (expected pass, got nonzero)"
fi

# 8. W-22, the scheme-coverage lint (TBX-5363). BatonSubsonicKitTests shipped and passed
# under `swift test` for a full release cycle while the Mac scheme never ran it, because
# adding the package's test target and adding it to app/project.yml's scheme are two
# separate steps and nothing forced the second one. Three overrides point the REAL block
# at a planted Packages/ tree, a planted project.yml and a planted allowlist, the same
# pattern as the import and dash lints above: this drives scripts/test.sh itself, not a
# copy of its logic.
run_scheme_lint_over() {   # $1 = Packages dir, $2 = project.yml, $3 = allowlist ("" = none)
  BATON_SCHEME_LINT_PACKAGES_DIR="$1" BATON_SCHEME_LINT_PROJECT_YML="$2" \
    BATON_SCHEME_LINT_ALLOWLIST="${3:-/dev/null}" LINT_ONLY=1 ./scripts/test.sh >/dev/null 2>&1
}
expect_scheme() {   # $1 = "clean"|"dirty", $2 = Packages dir, $3 = project.yml, $4 = name, $5 = optional allowlist
  run_scheme_lint_over "$2" "$3" "${5:-}"; local rc=$?
  if [ "$1" = clean ]; then
    [ "$rc" -eq 0 ] && ok "$4" || bad "$4 (expected pass, got $rc)"
  else
    [ "$rc" -ne 0 ] && ok "$4" || bad "$4 (expected FAIL, lint passed)"
  fi
}

# The defect itself: a package ships a Tests/ directory and project.yml's scheme never
# mentions it.
mkdir -p "$WORK/scheme-missing/Packages/FakeKit/Tests/FakeKitTests"
echo 'final class T {}' > "$WORK/scheme-missing/Packages/FakeKit/Tests/FakeKitTests/T.swift"
cat > "$WORK/scheme-missing/project.yml" <<'YML'
schemes:
  Baton:
    test:
      targets:
        - BatonTests
YML
expect_scheme dirty "$WORK/scheme-missing/Packages" "$WORK/scheme-missing/project.yml" \
  "a package with a Tests/ dir absent from the scheme is caught (the BatonSubsonicKit defect)"

# Add the scheme line for it and the same tree passes.
cat > "$WORK/scheme-missing/project.yml" <<'YML'
schemes:
  Baton:
    test:
      targets:
        - BatonTests
        - package: FakeKit/FakeKitTests
YML
expect_scheme clean "$WORK/scheme-missing/Packages" "$WORK/scheme-missing/project.yml" \
  "adding the scheme line clears the same tree"

# A dependency-only `package:` entry (no slash, the shape the top-level packages: block
# uses) must not be mistaken for a scheme test-target line, or a package could dodge the
# lint just by being a build dependency.
mkdir -p "$WORK/scheme-dep-only/Packages/FakeKit/Tests/FakeKitTests"
echo 'final class T {}' > "$WORK/scheme-dep-only/Packages/FakeKit/Tests/FakeKitTests/T.swift"
cat > "$WORK/scheme-dep-only/project.yml" <<'YML'
packages:
  FakeKit:
    path: ../Packages/FakeKit
targets:
  Baton:
    dependencies:
      - package: FakeKit
schemes:
  Baton:
    test:
      targets:
        - BatonTests
YML
expect_scheme dirty "$WORK/scheme-dep-only/Packages" "$WORK/scheme-dep-only/project.yml" \
  "a bare dependency 'package: FakeKit' line does not count as scheme wiring"

# Two packages whose names share a prefix must not cross-satisfy each other: adding
# BatonSubsonicKitExtra must not silence a missing BatonSubsonicKit, or vice versa.
mkdir -p "$WORK/scheme-prefix/Packages/FakeKit/Tests/FakeKitTests" \
         "$WORK/scheme-prefix/Packages/FakeKitExtra/Tests/FakeKitExtraTests"
echo 'final class T {}' > "$WORK/scheme-prefix/Packages/FakeKit/Tests/FakeKitTests/T.swift"
echo 'final class T {}' > "$WORK/scheme-prefix/Packages/FakeKitExtra/Tests/FakeKitExtraTests/T.swift"
cat > "$WORK/scheme-prefix/project.yml" <<'YML'
schemes:
  Baton:
    test:
      targets:
        - BatonTests
        - package: FakeKitExtra/FakeKitExtraTests
YML
expect_scheme dirty "$WORK/scheme-prefix/Packages" "$WORK/scheme-prefix/project.yml" \
  "a name-prefix match does not silence the shorter package that is actually missing"

# A package left out on purpose is silenced by the allowlist, and only that package: a
# second package with the same gap and no line of its own must still be caught, so the
# allowlist cannot be used to quiet the lint wholesale.
mkdir -p "$WORK/scheme-allowed/Packages/FakeKit/Tests/FakeKitTests" \
         "$WORK/scheme-allowed/Packages/OtherKit/Tests/OtherKitTests"
echo 'final class T {}' > "$WORK/scheme-allowed/Packages/FakeKit/Tests/FakeKitTests/T.swift"
echo 'final class T {}' > "$WORK/scheme-allowed/Packages/OtherKit/Tests/OtherKitTests/T.swift"
cat > "$WORK/scheme-allowed/project.yml" <<'YML'
schemes:
  Baton:
    test:
      targets:
        - BatonTests
YML
cat > "$WORK/scheme-allowed.txt" <<'TXT'
# comment lines and blanks are ignored

FakeKit: excluded on purpose for this test
TXT
expect_scheme dirty "$WORK/scheme-allowed/Packages" "$WORK/scheme-allowed/project.yml" \
  "both packages are caught with no allowlist" "$WORK/scheme-allowed.txt.missing"
expect_scheme dirty "$WORK/scheme-allowed/Packages" "$WORK/scheme-allowed/project.yml" \
  "the allowlist silences only the package it names, OtherKit still fires" "$WORK/scheme-allowed.txt"
rm -rf "$WORK/scheme-allowed/Packages/OtherKit"
expect_scheme clean "$WORK/scheme-allowed/Packages" "$WORK/scheme-allowed/project.yml" \
  "with only the allowlisted package left, the same tree is clean" "$WORK/scheme-allowed.txt"

# The real tree, with the real allowlist, is the shape a merge actually sees: BatonSpeech
# is the one live exception today (TBX-5354/PR #117 added its test target; the scheme line
# lands with TBX-5352/PR #116), and the allowlist file is what keeps this clean until then.
expect_scheme clean "Packages" "app/project.yml" \
  "the real Packages/ tree matches the real scheme, modulo the real allowlist" \
  "scripts/test-lint-scheme-allowlist.txt"

# With every override unset, the default run reads app/project.yml and Packages/ directly,
# which is the shape the merge gate actually runs.
if LINT_ONLY=1 ./scripts/test.sh >/dev/null 2>&1; then
  ok "the default (unscoped) scheme lint reads the real tree and is clean"
else
  bad "the default (unscoped) scheme lint reads the real tree and is clean (expected pass, got nonzero)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
