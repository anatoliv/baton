cask "baton" do
  # "<short>,<build>": Baton's appcast carries both sparkle:shortVersionString
  # and sparkle:version, and Homebrew's Sparkle livecheck strategy reports them
  # as one comma value. Pinning only the short version makes `brew audit` fail
  # with "differs from ... retrieved by livecheck" and breaks autobumping.
  version "0.20.3,120"
  sha256 "f29b7b91f7de8eceeb8188bdc9a88b4c658540f313fb76b18b1226c8b8bb0851"

  url "https://batonmusic.app/Baton-#{version.csv.first}.dmg"
  name "Baton"
  desc "Music player for a Navidrome/Subsonic library, controllable by AI agents"
  homepage "https://batonmusic.app/"

  # Baton auto-updates via Sparkle; track the signed appcast for new versions so
  # `brew livecheck` learns about a release from the same feed the app uses.
  livecheck do
    url "https://batonmusic.app/appcast.xml"
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
