cask "baton" do
  # "<short>,<build>": Baton's appcast carries both sparkle:shortVersionString
  # and sparkle:version, and Homebrew's Sparkle livecheck strategy reports them
  # as one comma value. Pinning only the short version makes `brew audit` fail
  # with "differs from ... retrieved by livecheck" and breaks autobumping.
  version "0.12.6,51"
  sha256 "8bfc902dd9d0ef2e0a72043a03e7c0dd0cfb801d4189ff0b8a6560e3733d7fc9"

  url "https://baton.tonebox.io/Baton-#{version.csv.first}.dmg",
      verified: "baton.tonebox.io/"
  name "Baton"
  desc "Music player for a Navidrome/Subsonic library, controllable by AI agents"
  homepage "https://baton.tonebox.io/"

  # Baton auto-updates via Sparkle; track the signed appcast for new versions so
  # `brew livecheck` learns about a release from the same feed the app uses.
  livecheck do
    url "https://baton.tonebox.io/appcast.xml"
    strategy :sparkle
  end

  # Sparkle owns upgrades. Without this, `brew upgrade` and the in-app updater
  # would both try to replace the bundle.
  auto_updates true
  depends_on macos: :sequoia
  depends_on arch: :arm64

  app "Baton.app"

  zap trash: [
    "~/Library/Application Support/Baton",
    "~/Library/Caches/io.tonebox.baton",
    "~/Library/HTTPStorages/io.tonebox.baton",
    "~/Library/Preferences/io.tonebox.baton.plist",
  ]
  # NOTE: the Navidrome server secret lives in the login Keychain (service
  # "io.tonebox.secrets") and is intentionally NOT removed by `zap` — a reinstall
  # should not silently lose the credential for a server you still use. Remove it
  # by hand from Keychain Access if you really want it gone.
end
