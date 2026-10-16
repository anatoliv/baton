import Foundation

/// An unscoped internal request never falls back to every foreground scene.
enum IncomingShareSceneScope {
    static func owns(_ requestedScene: UUID?, scene: UUID) -> Bool {
        requestedScene == scene
    }
}
