import Foundation

/// What a song's context menu offers, and what each item is called.
///
/// The two apps wrote this menu separately and drifted in the ways separate menus always
/// do — not in what they *did*, but in what they said and in what was there at all:
///
/// - The Mac wrote "Add to Playlist", the phone "Add to Playlist…". One of those promises
///   a submenu and the other a sheet, and both were telling the truth about themselves.
/// - The phone had **Go to Album** and **Go to Artist**; the Mac had neither, despite
///   having had the navigation machinery (`pendingSourceNavigation`) for versions.
/// - The ban item read "Never Play in Radio" on the phone and "Ban from Radio" on the Mac.
///
/// So this is the table — label, symbol, and the order they appear in — and nothing else.
/// The menus themselves stay per-platform on purpose: a macOS `contextMenu` with dividers
/// and an iOS one with a rating submenu are genuinely different chrome, and pretending
/// otherwise is how shared code turns into a switch on the platform.
public enum SongAction: String, CaseIterable, Sendable {
    case getInfo, play, playNext, addToQueue, startRadio
    case like, unlike, rate, goToAlbum, goToArtist
    case addToPlaylist, download, banFromRadio, allowInRadio, markForRemoval

    public var label: String {
        switch self {
        case .getInfo: "Get Info"
        case .play: "Play"
        case .playNext: "Play Next"
        case .addToQueue: "Add to Queue"
        case .startRadio: "Start Radio"
        case .like: "Like"
        case .unlike: "Unlike"
        case .rate: "Rate"
        // The ellipsis is a promise that something opens. The Mac's submenu did not open
        // anything, so it doesn't get one; the phone's sheet does.
        case .addToPlaylist: "Add to Playlist"
        case .goToAlbum: "Go to Album"
        case .goToArtist: "Go to Artist"
        case .download: "Download"
        case .banFromRadio: "Never Play in Radio"
        case .allowInRadio: "Allow in Radio"
        case .markForRemoval: "Mark for Removal"
        }
    }

    public var symbol: String {
        switch self {
        case .getInfo: "info.circle"
        case .play: "play.fill"
        case .playNext: "text.line.first.and.arrowtriangle.forward"
        case .addToQueue: "text.append"
        case .startRadio: "dot.radiowaves.left.and.right"
        case .like: "heart"
        case .unlike: "heart.slash"
        case .rate: "star"
        case .addToPlaylist: "music.note.list"
        case .goToAlbum: "square.stack"
        case .goToArtist: "music.mic"
        case .download: "arrow.down.circle"
        case .banFromRadio: "hand.raised"
        case .allowInRadio: "checkmark.circle"
        case .markForRemoval: "trash.slash"
        }
    }

    /// The label with its trailing ellipsis where the action opens a sheet. Platforms that
    /// present a submenu instead use `label`.
    public var sheetLabel: String { label + "…" }

    /// Reading order, so the two menus put the same things in the same place. Grouped:
    /// playback, then this song's metadata, then where it lives, then destructive-ish.
    public static let order: [SongAction] = [
        .getInfo, .play, .playNext, .addToQueue, .startRadio,
        .like, .unlike, .rate,
        .goToAlbum, .goToArtist, .addToPlaylist,
        .download, .banFromRadio, .allowInRadio, .markForRemoval,
    ]
}
