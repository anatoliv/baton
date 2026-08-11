import BatonPlaybackKit
import SwiftUI

/// A settings footer that explains the setting in plain words, and offers the long
/// version one tap away.
///
/// Settings had five sections with a footer and two with nothing at all, and the copy that
/// did exist described what a control *was* rather than what turning it on would do for
/// you. The fix isn't longer footers — a footer that runs to a paragraph is a wall people
/// stop reading. It's a short, concrete sentence plus a link into the guide, which already
/// contains the full explanation and is now navigable topic by topic.
///
/// The link goes through `HelpGuide.requestedTopicKey`, the same defaults key the Mac's
/// Help menu has always used to open its window at a section.
struct SettingsFooter: View {
    let text: String
    /// A `##` heading slug in HELP.md or FAQ.md. `SettingsHelpLinkTests` asserts every
    /// one of these resolves — a "Learn more" that opens Help at nothing is worse than
    /// no link, and nothing else would ever catch it.
    var topic: String?
    var onOpenHelp: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
            if let topic, let onOpenHelp {
                Button {
                    HelpGuide.requestTopic(topic)
                    onOpenHelp()
                } label: {
                    Text("Learn more")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Every Help topic a Settings footer points at.
///
/// Named rather than written inline at each call site so the test has one list to check
/// and a renamed heading fails once, loudly, instead of silently breaking a link nobody
/// taps until a user does.
enum SettingsHelpTopic {
    static let equalizer = "the-equalizer"
    static let soundQuality = "sound-quality-gapless-crossfade-loudness"
    static let queue = "the-queue-shuffle-repeat-and-autoplay"
    static let scrobbling = "scrobbling"
    static let downloads = "downloads-and-offline-listening"
    static let musicFriend = "letting-an-agent-control-your-music"
    static let privacy = "privacy-and-security"
    static let gettingConnected = "getting-connected"

    static let all: [String] = [
        equalizer, soundQuality, queue, scrobbling,
        downloads, musicFriend, privacy, gettingConnected,
    ]
}
