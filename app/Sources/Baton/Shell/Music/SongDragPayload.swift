import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Songs being dragged, by id.
///
/// Baton has had drag-and-drop since the queue shipped, but only *inside* one list —
/// reorder the queue, reorder a playlist. Dragging a track from a browse list onto a
/// playlist in the sidebar, which is the gesture the Finder taught everyone and the one
/// every desktop music app has, did nothing at all. The pieces were all present: the rows
/// know their song, the sidebar knows its playlists, and `addToPlaylist` has existed for
/// versions. Only the drag contract was missing.
///
/// Ids rather than whole songs: the drop target re-reads from the library store anyway, a
/// pasteboard is not a place to put a user's metadata, and an id survives a drag that
/// outlives the row it came from.
struct SongDragPayload: Codable, Transferable {
    var ids: [String]

    /// Plural from the start. The Mac's browse lists already support Finder-style
    /// shift-click multi-select, so a drag that could only ever carry one track would have
    /// been wrong the first time somebody selected three.
    init(ids: [String]) { self.ids = ids }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .batonSongIDs)
        // A plain-text fallback so dragging a track somewhere outside Baton produces
        // something legible rather than silently nothing. A closure, not a key path — a
        // key path cannot call `joined`, and the closure has to be `@Sendable` because a
        // drag is carried across actors.
        ProxyRepresentation(exporting: { @Sendable payload in payload.ids.joined(separator: "\n") })
    }
}

extension UTType {
    /// Baton's own drag type. Declared rather than reusing `.text` so a drop target can
    /// tell "three songs from Baton" from "some text that happens to be on the pasteboard".
    static let batonSongIDs = UTType(exportedAs: "io.tonebox.baton.song-ids")
}
