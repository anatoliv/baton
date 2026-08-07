# Working on Baton

Two apps from one repo: a macOS app (`app/`) and an iPhone app (`ios/`), over shared
Swift packages (`Packages/`) and a small set of files both compile (`Shared/`).

## Releasing

**Mac** — `./scripts/publish.sh` with:

```sh
export SIGN_ID="Developer ID Application: Anatoli Vishnyakov (Q8822GNL2H)"
export NOTARY_PROFILE="tonebox-notarize"     # NOT "baton-notary" — one profile per Developer ID
export SPARKLE_BIN="$(echo ~/Library/Developer/Xcode/DerivedData/Baton-*/SourcePackages/artifacts/sparkle/Sparkle/bin)"
export WEB01="web-01" APPCAST_HOST="baton.tonebox.io" PUBLISH=1
./scripts/publish.sh
```

Bump `MARKETING_VERSION` **and** `CURRENT_PROJECT_VERSION` in `app/project.yml` first —
Sparkle compares the build number, and it must strictly increase. Add a What's New entry
in `BatonHelpContent.swift` for the new version; the gate refuses to publish without one.
**A dirty tree is refused**, so commit before publishing.

**iPhone** — `./ios/scripts/testflight.sh`. Bump `MARKETING_VERSION` in `ios/project.yml`
and add a `ReleaseNote` in `HelpView.swift`. The build number is generated, so it always
increases on its own.

### How long these actually take

Measured, not guessed. Anything much past these is a stall, not slowness.

| Step | Normal |
|---|---|
| Mac: test gate (808 tests + conversation eval) | 8–12 min |
| Mac: build, sign, package DMG | 3–5 min |
| **Mac: notarize + staple** | **3–5 min** |
| Mac: symbols, appcast, publish, tag | 2–3 min |
| **Mac total** | **~20 min** |
| **iPhone: whole `testflight.sh`** | **4–6 min** |

### When it takes longer than usual

**Investigate; don't wait it out.** Both stalls seen so far were in `notarytool submit`,
which hangs during *upload* — and its `--timeout` flag only covers the wait for Apple's
verdict, so the flag never fires. One stall ran 69 minutes, another 18, both ended by hand.
`publish.sh` now wraps the submit in a 15-minute wall clock with two retries, so this
should self-recover; if you are watching one that doesn't:

```sh
# 1. How long has it actually been?
ps -o pid=,etime= -p $(pgrep -f "notarytool submit" | head -1)

# 2. The decisive check: did the upload reach Apple at all?
xcrun notarytool history --keychain-profile tonebox-notarize | head -20
```

If the DMG is **not** listed in that history, the upload never landed and waiting will not
help. Kill it and re-run:

```sh
pkill -f "notarytool submit"; pkill -f "scripts/publish.sh"
```

Then confirm nothing was half-published before retrying — all three should show the *old*
version, and the tree stays safe to retry:

```sh
curl -s https://baton.tonebox.io/appcast.xml | grep shortVersionString   # still the old one
git tag --list "v<new-version>"                                          # empty
xcrun stapler validate dist/Baton-<new>.dmg                              # "does not have a ticket"
```

The publish is ordered so this is safe: nothing reaches web-01 until notarization and
stapling succeed, and the tag is written last.

### After a Mac publish

1. **Verify the DMG as web-01 serves it**, not the local file — that is the check that
   catches a bad upload:
   `curl -sL https://baton.tonebox.io/Baton-<v>.dmg | shasum -a 256`
2. `./scripts/publish-site.sh` — deploys the landing page (needs `WEB01`).
3. `./scripts/publish-repo.sh` — pushes the public mirror so `brew` can install it.
4. Commit the cask + landing page: `publish.sh` rewrites them *after* the DMG exists, so
   they always land one commit behind the tag.

### The conversation eval

The Mac test gate includes `RemoteAgentConversationEval`, which talks to a real model on
the LAN (`~/.baton-live-agent.json`). If that host is asleep the eval **skips**, which is
correct — an unreachable provider is *not measurable*, not broken.

The subtle case, which failed a release: the host answered its port while still loading
its model, so the reachability check passed and every request returned nonsense — 53 wrong
out of 114, reported as a broken agent whose code had not changed. The guard now sends one
trivial prompt and skips unless the model actually answers. If you see a wild eval score,
check the model host before believing it.

## Habits this codebase expects

- **Verify against the running app, not the code.** Several features here passed their
  tests while being visibly broken: a grid whose cells all measured the same because none
  had loaded, a mix card nothing could tap, an equalizer whose coefficients were perfect
  and never applied. Screenshots and a real walk catch what assertions miss.
- **Read the result bundle, not the log.** `xcresulttool get test-results summary` is the
  authority; the log has reported a 790-test run as "Executed 4 tests" and a run with five
  crashes as "0 failures".
- **Check the test count, not just the tick.** A suite that quietly lost four tests looks
  exactly like a healthy one.
- **When something exists in more than one place, put it in one.** Nine Shuffle call sites,
  eleven layout keys, twelve now-playing indicators — each drifted apart before being
  unified, and each drift shipped.
- **Sweep by meaning, not by name.** Searching for `waveform` missed the row drawing
  `speaker.wave.2.fill` for the identical state.
