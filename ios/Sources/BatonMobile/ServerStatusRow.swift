import BatonSubsonicKit
import SwiftUI

/// Whether the server is actually answering, right now.
///
/// Settings listed an address and a username and left it there, which tells you what Baton
/// was *configured* with, not whether any of it works. Those are different questions, and
/// the one people open Settings to ask is the second — after a password change, a server
/// move, a VPN, or a library that has stopped loading for reasons nobody can see.
///
/// So this pings. It deliberately does not derive a green light from "credentials exist" or
/// "we loaded something earlier": a badge that says Connected without having checked is
/// worse than no badge, because it is believed. Every state here is the result of a request
/// that just happened, and the failure states say what failed — a rejected password and an
/// unreachable host need different actions from you, and "not connected" would hide that.
@MainActor
@Observable
final class ServerStatus {
    enum State: Equatable {
        case unknown
        case checking
        case connected(openSubsonic: Bool)
        /// Reached the server; it refused the sign-in.
        case rejected
        /// Nothing answered.
        case unreachable(String)
        /// Not a failure — offline mode is a choice, and downloads still play.
        case offline

        var label: String {
            switch self {
            case .unknown: "Not checked"
            case .checking: "Checking…"
            case .connected: "Connected"
            case .rejected: "Sign-in refused"
            case .unreachable: "Can't reach server"
            case .offline: "Offline mode"
            }
        }

        var symbol: String {
            switch self {
            case .unknown: "circle"
            case .checking: "arrow.triangle.2.circlepath"
            case .connected: "checkmark.circle.fill"
            case .rejected: "lock.circle.fill"
            case .unreachable: "exclamationmark.triangle.fill"
            case .offline: "airplane.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .unknown, .checking: .secondary
            case .connected: .green
            case .rejected: .orange
            case .unreachable: .red
            case .offline: .blue
            }
        }

        /// The line under the badge. Nil when the badge says enough on its own.
        var detail: String? {
            switch self {
            // Only claimed when the server actually advertised extensions, since that is
            // the one thing the ping proves beyond "it answered".
            case .connected(let openSubsonic): openSubsonic ? "OpenSubsonic extensions available" : nil
            case .rejected: "The server answered but wouldn't accept this sign-in. Your password may have changed."
            case .unreachable(let why): why
            case .offline: "Playing downloads only. Nothing is being streamed."
            default: nil
            }
        }
    }

    private(set) var state: State = .unknown

    /// Pings the active server. Cheap — `verify` is one authenticated request plus a
    /// best-effort extensions probe — so it can run whenever Settings appears.
    func check() async {
        guard !StreamingPlaybackController.isOfflineMode else {
            state = .offline
            return
        }
        let url = NavidromeConfig.serverURLString
        guard !url.isEmpty else {
            state = .unknown
            return
        }

        state = .checking
        do {
            let info = try await NavidromeConfig.verify(
                urlString: url,
                username: NavidromeConfig.username,
                secret: NavidromeConfig.secret,
                authMode: NavidromeConfig.authMode
            )
            state = .connected(openSubsonic: !info.extensions.isEmpty)
        } catch {
            // Told apart because they need different things from you: one is a password to
            // fix, the other is a network or a server that is down. Collapsing them into
            // "not connected" is how someone spends an evening re-typing a correct password.
            state = Self.isAuthFailure(error)
                ? .rejected
                : .unreachable(Self.describe(error))
        }
    }

    /// A refused sign-in, as opposed to a server that isn't there.
    ///
    /// Subsonic reports bad credentials as a *protocol* error inside a 200 response, not an
    /// HTTP 401 — so checking the status code alone would file every wrong password under
    /// "can't reach server" and send people to debug their network.
    static func isAuthFailure(_ error: Error) -> Bool {
        guard let navidrome = error as? NavidromeError else { return false }
        switch navidrome {
        case .unauthorized, .notConfigured:
            return true
        case .http(let status):
            return status == 401 || status == 403
        case .subsonic(let code, _):
            // 40 wrong username/password · 41 token auth not supported · 44 invalid API key
            // · 50 user not authorized for the operation.
            return [40, 41, 44, 50].contains(code)
        default:
            return false
        }
    }

    static func describe(_ error: Error) -> String {
        if case let .transport(message)? = error as? NavidromeError { return message }
        if case let .http(status)? = error as? NavidromeError {
            return "The server answered with HTTP \(status)."
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet: return "This iPhone has no internet connection."
            case .timedOut: return "The server didn't answer in time."
            case .cannotFindHost, .cannotConnectToHost: return "Nothing is answering at that address."
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return "The server's HTTPS certificate wasn't accepted."
            default: break
            }
        }
        return error.localizedDescription
    }
}

/// The badge itself — a row you can tap to re-check.
struct ServerStatusRow: View {
    let status: ServerStatus
    var onRecheck: () -> Void

    var body: some View {
        Button(action: onRecheck) {
            HStack(spacing: 10) {
                Image(systemName: status.state.symbol)
                    .foregroundStyle(status.state.tint)
                    .symbolEffect(.rotate, isActive: status.state == .checking)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.state.label).foregroundStyle(.primary)
                    if let detail = status.state.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if status.state != .checking {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(status.state == .checking)
        // One element for VoiceOver, and a stable handle for the UI test — a badge that
        // claims a connection is exactly the kind of thing that must be asserted rather
        // than admired.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ServerStatus")
        .accessibilityHint("Double tap to check the connection again")
    }
}
