# Release & appcast hosting (Sparkle)

How to cut a Baton release and publish it to the auto-update channel. The app's
Sparkle wiring is already live (`SparkleUpdater`, `UpdateChannel`, the "Check
for Updates" menu item, and the `SUFeedURL` / `SUPublicEDKey` /
`SUEnableAutomaticChecks` Info.plist keys in `app/project.yml`).

The whole release is automated by **`scripts/publish.sh`**. Everything that
needs no credentials runs unconditionally (build a Release `.app`, package a
DMG, compute sha256 + length, emit `dist/appcast.xml`); the credentialed stages
(Developer-ID sign, notarize/staple, Sparkle EdDSA signature, and the upload)
run only when the matching env vars are set — so the script is safe to run
locally as a dry run, and becomes a full publish when you opt in with
`PUBLISH=1`.

Design mirrors Tonebox's: an EdDSA-signed appcast, a signed + notarized `.app`
inside a DMG, and a static `appcast.xml` served over HTTPS from Baton's own site
(`baton.tonebox.io/appcast.xml`, the `baton_web` nginx container on web-01), so
no new host is needed.

## The pipeline at a glance

`scripts/publish.sh` runs these stages in order; each credentialed stage is
skipped (with a note) when its env var is absent:

| # | Stage | Needs | Notes |
|---|---|---|---|
| 0 | Test gate (`scripts/test.sh`) | — | Refuses to continue if tests fail |
| 1 | Release build (`xcodebuild`, wiped derived data) | — | → `Baton.app` |
| 2 | Codesign (Developer ID, hardened runtime, `--timestamp`) | `SIGN_ID` | Skipped → unsigned local artifact |
| 4 | Package DMG (`hdiutil`, `/Applications` symlink) | — | → `dist/Baton-<version>.dmg` |
| 3 | Notarize + staple (`notarytool submit --wait`, `stapler`, `spctl`) | `SIGN_ID` + `NOTARY_PROFILE` | Signs the DMG too, then Gatekeeper-checks |
| 5 | Appcast item (`sign_update`) | `SPARKLE_BIN` | Real `edSignature`; else a `PLACEHOLDER` |
| 6 | Publish (atomic scp, origin-verify, tag) | `PUBLISH=1` + `WEB01` (+ 2/3/5) | DMG first, then appcast; refuses a broken/unsigned feed |

## Env-var interface

| Var | Purpose | Example |
|---|---|---|
| `SIGN_ID` | Developer ID Application identity in the login Keychain | `Developer ID Application: Your Name (TEAMID)` |
| `NOTARY_PROFILE` | notarytool Keychain profile name (see one-time setup) | `baton-notary` |
| `SPARKLE_BIN` | Sparkle `bin/` dir (holds `sign_update` / `generate_keys`) | `~/Library/Developer/Xcode/DerivedData/Baton-*/SourcePackages/artifacts/sparkle/Sparkle/bin` |
| `WEB01` | SSH target for the appcast host | `user@host` (an `~/.ssh/config` alias or `user@<ip>`) |
| `PUBLISH` | Opt in to the upload stage | `1` |
| `APPCAST_HOST` | Download host in the enclosure URL (default `baton.tonebox.io`) | `baton.tonebox.io` |
| `REMOTE_DIR` | nginx docroot on `WEB01` (default `/opt/docker/baton-web/site`) | `/opt/docker/baton-web/site` |

## One-time setup

### 1. Sparkle signing key (EdDSA)

Signs every release. The **private key never leaves the release Mac** (Sparkle
stores it in the login Keychain); only the public key goes in the repo.

```sh
SPARKLE_BIN="$(echo ~/Library/Developer/Xcode/DerivedData/Baton-*/SourcePackages/artifacts/sparkle/Sparkle/bin)"
"$SPARKLE_BIN/generate_keys"        # stores the private key in the login Keychain
"$SPARKLE_BIN/generate_keys" -p     # prints the PUBLIC key to paste below
```

Paste the public key into `app/project.yml` `SUPublicEDKey` and commit it (it's
not secret). `publish.sh` preflights that the private key still matches this
value and refuses to publish if not — otherwise installed apps would reject the
update's signature.

> Never commit the private key. Back it up out-of-band (a password manager) so
> releases survive a lost Mac. `publish-repo.sh`'s secrets guard blocks
> `-----BEGIN … PRIVATE KEY` as a backstop.

### 2. Notarization credentials (notarytool profile)

Store your Apple ID + app-specific password once, so notarytool reads them from
the Keychain by name and no secret appears in a command or log:

```sh
xcrun notarytool store-credentials "baton-notary" \
  --apple-id "<your-apple-id-email>" \
  --team-id "<TEAMID>" \
  --password "<app-specific-password>"   # appleid.apple.com → App-Specific Passwords
```

Then pass `NOTARY_PROFILE=baton-notary`. Rotate/revoke the app-specific password
anytime; regenerate the profile if you do.

## Per release

1. **Bump the version** in `app/project.yml`:
   - `MARKETING_VERSION` — the marketing string (e.g. `0.3.0`).
   - `CURRENT_PROJECT_VERSION` — the **build number**, which must strictly
     increase every release. Sparkle compares this (`sparkle:version`) against
     the installed `CFBundleVersion` to decide whether an update is newer, so
     this — not the marketing string — is what gates the update.
   Update the **What's New** card (`BatonHelpContent.swift`) and any `HELP.md` /
   `FAQ.md` wording, then **commit** — the publish stage refuses a dirty tree so
   every release is reproducible from a tagged commit.

2. **Dry run (no credentials, or omit `PUBLISH`)** to verify the build + DMG +
   appcast are produced cleanly:

   ```sh
   ./scripts/publish.sh          # stops after local artifacts in dist/
   ```

3. **Full publish** — set all four credential inputs and `PUBLISH=1`:

   ```sh
   SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
   NOTARY_PROFILE="baton-notary" \
   SPARKLE_BIN="$(echo ~/Library/Developer/Xcode/DerivedData/Baton-*/SourcePackages/artifacts/sparkle/Sparkle/bin)" \
   WEB01="user@host" \
   PUBLISH=1 \
   ./scripts/publish.sh
   ```

   Stage 6 uploads the **DMG first, then the appcast** (each to a temp name then
   an atomic `mv`, so the feed never points at a missing download), then
   **origin-verifies** that `https://<APPCAST_HOST>/<dmg>` serves exactly the
   advertised byte length, and force-tags `v<version>`.

4. **Take the channel live (first release only):** set `SUPublicEDKey` to the
   real key and flip `SUEnableAutomaticChecks: true` in `app/project.yml`, then
   ship a build with those baked in. (Already done as of 0.1.0.)

5. **Verify end-to-end:** `curl -s https://baton.tonebox.io/appcast.xml` shows
   the new `sparkle:shortVersionString` + `edSignature`, and from an older build
   **Check for Updates** finds it, validates the signature, downloads, installs.

## Guards the script enforces (why a publish can refuse)

- **Dirty tree** with `PUBLISH=1` → aborts (releases must be reproducible).
- **Sparkle key mismatch** vs `SUPublicEDKey` → aborts (updates would fail to verify).
- **No EdDSA signature** (missing `SPARKLE_BIN`) or **unsigned build** (missing
  `SIGN_ID`) with `PUBLISH=1` → aborts (never ship an unverifiable/unsigned feed).
- **Origin verify** mismatch (served bytes ≠ advertised length) → aborts.

## Notes

- The appcast URL is public and unauthenticated (Baton is free); no `?k=`
  early-access token like Tonebox uses.
- Keep past `<item>`s in `appcast.xml` so users on old versions still see a path
  forward; Sparkle picks the newest applicable one. (The current script writes a
  single-item feed; add prior items if you need to preserve a longer history.)
- The site payload itself (the `baton.tonebox.io` pages) deploys separately via
  `scripts/publish-site.sh`; `publish.sh` only writes the DMG + `appcast.xml`
  into the same docroot.
- Never hard-code the appcast host's LAN address in the repo — pass it at
  runtime via `WEB01`; `publish-repo.sh`'s secrets guard blocks private IPs.
