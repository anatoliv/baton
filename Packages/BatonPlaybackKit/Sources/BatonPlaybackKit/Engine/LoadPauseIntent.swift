/// A pause made before a stream has connected must fence its later render admission.
/// Keeping the policy until load completion also prevents an immediate ownership handoff
/// from being weakened back into a deferred fade by the asynchronous loader.
enum LoadPauseIntent: Equatable {
    case none, faded, immediate
    var allowsRendering: Bool { self == .none }
    var immediatePause: Bool? {
        switch self { case .none: nil; case .faded: false; case .immediate: true }
    }
}
