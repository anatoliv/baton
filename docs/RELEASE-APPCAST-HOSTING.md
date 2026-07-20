# Release & appcast hosting (Sparkle)

How to cut a Baton release and take the auto-update channel live. The app's
Sparkle wiring is already in place (`SparkleUpdater`, `UpdateChannel`, the
"Check for Updates" menu item, and the `SUFeedURL` / `SUPublicEDKey` /
`SUEnableAutomaticChecks` Info.plist keys in `app/project.yml`). Until the
steps below are done, the in-app UI honestly shows "Not available yet" and the
check is disabled, because `SUPublicEDKey` is still the placeholder and
`SUEnableAutomaticChecks` is `false`.

Design mirrors Tonebox's: an EdDSA-signed appcast, a signed + notarized `.app`
inside a DMG, and a static `appcast.xml` hosted over HTTPS. Baton serves its
appcast from its own site (`baton.tonebox.io/appcast.xml`, the `baton_web`
nginx container on web-01), so no new host is needed.

## One-time: generate the signing key

The EdDSA key pair signs every release. The **private key never leaves the
release Mac** (Sparkle stores it in the login Keychain); only the public key
goes in the repo.

```sh
# generate_keys ships with the Sparkle SPM artifact. After a build, find it under:
#   ~/Library/Developer/Xcode/DerivedData/Baton-*/SourcePackages/artifacts/sparkle/Sparkle/bin/
./generate_keys                # stores the private key in the login Keychain
./generate_keys -p             # prints the PUBLIC key to paste below
```

Paste the public key into `app/project.yml` `SUPublicEDKey` (replace
`REPLACE_WITH_SPARKLE_ED25519_PUBLIC_KEY`). Commit that; it's not secret.

> Never commit the private key. Back it up out-of-band (e.g. a password
> manager) so releases survive a lost Mac. The `publish-repo.sh` secrets guard
> blocks `-----BEGIN … PRIVATE KEY` as a backstop.

## Per release

1. **Build + sign + notarize** a Release `.app`, staple it, and package it in a
   DMG (`Baton_<version>_aarch64.dmg`). Confirm Gatekeeper accepts it
   (`spctl -a -vv` reports "Notarized Developer ID").
2. **Sign the appcast item** with the private key:

   ```sh
   ./sign_update Baton_<version>_aarch64.dmg
   # prints sparkle:edSignature="…" length="…"
   ```
3. **Assemble `appcast.xml`** with an `<item>` for the release: title, version
   (`sparkle:version` = build, `sparkle:shortVersionString` = marketing),
   `<enclosure url=…>` pointing at the DMG's public URL, the `edSignature` +
   `length` from step 2, and a `<sparkle:minimumSystemVersion>15.0</…>`.
   Validate the XML.
4. **Publish** the DMG and `appcast.xml` where `SUFeedURL` points. Add both to
   the site payload (`website/appcast.xml` + the DMG on a releases host) and
   deploy with `scripts/publish-site.sh`, or upload directly to
   `/opt/docker/baton-web/site/` on web-01.
5. **Take the channel live** (first release only): set `SUPublicEDKey` to the
   real key (step above) and flip `SUEnableAutomaticChecks: true` in
   `app/project.yml`, then ship a build with those baked in. `UpdateChannel`
   now reports "Ready", the menu item enables, and auto-checks begin.
6. **Verify end-to-end**: from an older build, Check for Updates finds the
   new version, validates the signature, downloads, and installs.

## Notes

- The appcast URL is public and unauthenticated (Baton is free); no `?k=`
  early-access token like Tonebox uses.
- Keep past `<item>`s in `appcast.xml` so users on old versions still see a path
  forward; Sparkle picks the newest applicable one.
- Update the Updates wording in `HELP.md` / `FAQ.md` / `website/help.html` once
  the channel is live (it currently says updates are planned).
