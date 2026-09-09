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

# 4. W-19, the accessibility lint. It is scoped to a list of primary-path file names, so a
#    planted violation has to carry one of those names to be in scope — which is itself the
#    assertion that the scoping works, since the same violation under another name passes.
mkdir -p "$WORK/icon-multiline" "$WORK/icon-oneline" "$WORK/icon-out-of-scope" "$WORK/icon-labelled"
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

# The identical violation outside the scoped list must pass, or the list means nothing.
cp "$WORK/icon-multiline/NowPlayingBar.swift" "$WORK/icon-out-of-scope/SomeOtherPane.swift"
expect clean "$WORK/icon-out-of-scope" "the same violation outside the scoped files is not flagged"

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

# 5. The real tree must be clean, which is also a check that the patterns still match the
#    code's shape rather than having rotted into matching nothing.
expect clean "app/Sources/Baton" "the real source tree is clean"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
