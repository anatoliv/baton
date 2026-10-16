import Foundation

/// Session admission state, independent of platform audio APIs. A received song never
/// grants an interruption permission to restart the library it deliberately paused.
public struct ReceivedAudioOwnership: Sendable {
    public private(set) var token: UUID?
    public private(set) var allowsLibraryResume = true
    public init() {}
    public mutating func begin() -> UUID {
        let token = UUID()
        self.token = token
        allowsLibraryResume = false
        return token
    }
    @discardableResult public mutating func release(_ token: UUID) -> Bool {
        guard self.token == token else { return false }
        self.token = nil
        // Only another explicit library admission restores automatic library resumption.
        return true
    }
    public mutating func libraryWillStart() {
        token = nil
        allowsLibraryResume = true
    }
}

public enum ReceivedAudioEvent: Equatable, Sendable { case interrupted, routeRemoved, mediaServicesReset, libraryStarting }
