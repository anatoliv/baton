import Foundation

/// Memory-only request identity, independent of UIKit's asynchronous transitions.
/// The token distinguishes changed keys for the same share and repeated A → B → A links.
struct IncomingSharePresentationState<Invitation: Equatable> {
    struct Request {
        let token: UUID
        let invitation: Invitation
    }
    enum Phase: Equatable { case idle, presenting(UUID), visible(UUID), dismissing(UUID) }
    enum Action { case present(Request), replace(Request), dismiss(UUID) }
    private(set) var request: Request?
    private(set) var phase: Phase = .idle

    mutating func receive(_ invitation: Invitation?, token: UUID? = nil) {
        guard request?.invitation != invitation || (token != nil && token != request?.token) else { return }
        request = invitation.map { Request(token: token ?? UUID(), invitation: $0) }
    }
    func isCurrent(_ token: UUID, sourceToken: UUID? = nil) -> Bool {
        request?.token == token && (sourceToken == nil || sourceToken == token)
    }
    func canActivateAudio(_ token: UUID, sourceToken: UUID, foreground: Bool) -> Bool {
        foreground && isCurrent(token, sourceToken: sourceToken)
            && (phase == .presenting(token) || phase == .visible(token))
    }
    /// Clear decrypted content immediately, before a renderer may defer for lifecycle/alerts.
    func needsPrivateContentClear(sourceToken: UUID) -> Bool {
        switch phase {
        case .idle: return false
        case let .presenting(token), let .visible(token), let .dismissing(token):
            return !isCurrent(token, sourceToken: sourceToken)
        }
    }
    @discardableResult mutating func close(_ token: UUID) -> Bool {
        guard isCurrent(token) else { return false }
        request = nil
        return true
    }
    mutating func next(canPresent: Bool) -> Action? {
        switch phase {
        case .idle:
            guard canPresent, let request else { return nil }
            phase = .presenting(request.token)
            return .present(request)
        case let .visible(token):
            guard let request else { phase = .dismissing(token); return .dismiss(token) }
            guard token != request.token else { return nil }
            phase = .visible(request.token)
            return .replace(request)
        case .presenting, .dismissing: return nil
        }
    }
    mutating func presented(_ token: UUID) {
        guard phase == .presenting(token) else { return }
        phase = .visible(token)
    }
    mutating func dismissed(_ token: UUID) {
        guard phase == .presenting(token) || phase == .dismissing(token) || phase == .visible(token) else { return }
        phase = .idle
    }
    mutating func clear() { request = nil; phase = .idle }
}
