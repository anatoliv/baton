#if DEBUG
import AppKit
import Foundation
import MediaPlayer

/// DEBUG only: what this app has handed the system's Now Playing (Control Center, the menu bar
/// widget, the media keys' HUD), read back from `MPNowPlayingInfoCenter`, so a probe can check
/// the artwork the system shows without driving Control Center. Added to
/// `baton://now-playing` as `system_now_playing`. With `BATON_DEBUG_NOW_PLAYING_ARTWORK_DUMP`
/// set to a file path (by environment, never argv), the artwork is also written there as a PNG.
enum BatonMCPNowPlayingDebug {
    @MainActor
    static func systemNowPlaying() -> [String: Any] {
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        var out: [String: Any] = [
            "title": info[MPMediaItemPropertyTitle] as? String ?? "",
            "album": info[MPMediaItemPropertyAlbumTitle] as? String ?? "",
        ]
        guard let artwork = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork else {
            out["artwork"] = NSNull()
            return out
        }
        out["artwork"] = ["width": Int(artwork.bounds.width), "height": Int(artwork.bounds.height)]
        if let path = ProcessInfo.processInfo.environment["BATON_DEBUG_NOW_PLAYING_ARTWORK_DUMP"], !path.isEmpty,
           let image = artwork.image(at: artwork.bounds.size), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
           (try? png.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil {
            out["artwork_dump"] = path
        }
        return out
    }
}
#endif
