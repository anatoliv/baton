import SwiftUI

import BatonSubsonicKit

/// Whether a configured service is actually answering, right now.
///
/// Settings is a list of addresses and keys, which tells you what Baton was *configured*
/// with, not whether any of it works. Those are different questions, and the one people open
/// Settings to ask is the second — after a password change, a host that moved, a VPN, a key
/// that expired, or a feature that has quietly stopped working for reasons nothing on screen
/// explains.
///
/// The rule every service here follows: **a green light is the result of a request that just
/// happened.** Never derived from "a key exists" or "we loaded something earlier". A badge
/// that claims Connected without having checked is worse than no badge, because it is
/// believed — Settings → Scrobbling showed a green "Scrobbling to ListenBrainz" for any
/// non-empty string in the token field, including a typo.
///
/// Failure is split rather than collapsed into "not connected", because the two halves need
/// different things from you: a refused credential is something you fix here, an unreachable
/// host is a network or a server that is down. Collapsing them is how someone spends an
/// evening re-typing a correct password.
///
/// Lives in `Shared/` because both apps ask this about the same services, and the vocabulary
/// drifting apart is how one of them ends up with a light that means something else.
enum ServiceStatus: Equatable {
    /// Nothing to check yet. The string says what is missing, and it is not an error.
    case notConfigured(String)
    /// Configured, never checked. Deliberately not green.
    case unknown
    case checking
    /// It answered. `detail` is the one extra thing the check proved; `badge` is a number
    /// worth showing inline (voice counts, model counts).
    case ok(detail: String? = nil, badge: String? = nil)
    /// Reached it; it refused the credential.
    case refused(String)
    /// Nothing answered.
    case unreachable(String)
    /// Not a failure — offline mode is a choice, and downloads still play.
    case offline

    var label: String {
        switch self {
        case let .notConfigured(what): what
        case .unknown: "Not checked"
        case .checking: "Checking…"
        case .ok: "Connected"
        case .refused: "Sign-in refused"
        case .unreachable: "Can't reach it"
        case .offline: "Offline mode"
        }
    }

    var symbol: String {
        switch self {
        case .notConfigured: "circle.dashed"
        case .unknown: "circle"
        case .checking: "arrow.triangle.2.circlepath"
        case .ok: "checkmark.circle.fill"
        case .refused: "lock.circle.fill"
        case .unreachable: "exclamationmark.triangle.fill"
        case .offline: "airplane.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notConfigured, .unknown, .checking: .secondary
        case .ok: .green
        case .refused: .orange
        case .unreachable: .red
        case .offline: .blue
        }
    }

    /// The line under the badge. Nil when the badge says enough on its own.
    var detail: String? {
        switch self {
        case let .ok(detail, _): detail
        case let .refused(why): why
        case let .unreachable(why): why
        case .offline: "Playing downloads only. Nothing is being streamed."
        default: nil
        }
    }

    /// The small number beside a green tick, when the check counted something.
    var badge: String? {
        if case let .ok(_, badge) = self { return badge }
        return nil
    }

    var isChecking: Bool { self == .checking }

    /// A refused sign-in, as opposed to a service that isn't there.
    ///
    /// Subsonic reports bad credentials as a *protocol* error inside a 200 response, not an
    /// HTTP 401 — so checking the status code alone would file every wrong password under
    /// "can't reach server" and send people to debug their network.
    static func isAuthFailure(_ error: Error) -> Bool {
        guard let navidrome = error as? NavidromeError else { return false }
        switch navidrome {
        case .unauthorized, .notConfigured:
            return true
        case let .http(status):
            return status == 401 || status == 403
        case let .subsonic(code, _):
            // 40 wrong username/password · 41 token auth not supported · 44 invalid API key
            // · 50 user not authorized for the operation.
            return [40, 41, 44, 50].contains(code)
        default:
            return false
        }
    }

    /// What went wrong, in words that name the thing to go and fix.
    ///
    /// Device-neutral on purpose: this file is compiled by both apps, and "this iPhone has no
    /// internet connection" is wrong half the time it would be shown.
    static func describe(_ error: Error) -> String {
        if case let .transport(message)? = error as? NavidromeError { return message }
        if case let .http(status)? = error as? NavidromeError {
            return "The server answered with HTTP \(status)."
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet: return "There's no internet connection."
            case .timedOut: return "It didn't answer in time."
            case .cannotFindHost, .cannotConnectToHost: return "Nothing is answering at that address."
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return "The HTTPS certificate wasn't accepted."
            default: break
            }
        }
        return error.localizedDescription
    }

    /// The common shape of a probe: run the check, turn whatever happened into a status.
    /// Every caller wants the same three lines around its one request.
    /// `#isolation` so the check runs where its caller already is — every one of them is a
    /// view or a `@MainActor` model, and hopping actors just to make one request would make
    /// the closure's captures a concurrency problem for no gain.
    static func probing(
        isolation: isolated (any Actor)? = #isolation,
        _ check: () async throws -> Self
    ) async -> Self {
        do {
            return try await check()
        } catch {
            if isAuthFailure(error) { return .refused(Self.refusedDetail) }
            return .unreachable(describe(error))
        }
    }

    /// Said the same way everywhere, because it is the same situation everywhere: the address
    /// is right, the credential isn't.
    static let refusedDetail = "It answered but wouldn't accept this sign-in. The password or key may have changed."
}

// MARK: - Presentation

/// The compact form: a tick or a warning beside the field it belongs to, with the detail in
/// a tooltip. For rows where the address is the subject and the status is an annotation.
struct ServiceStatusBadge: View {
    let status: ServiceStatus

    var body: some View {
        Group {
            switch status {
            case .unknown, .notConfigured:
                // Holds the space so the field doesn't jump when a check finishes.
                Color.clear.frame(width: 16, height: 16)
            case .checking:
                ProgressView().controlSize(.small).frame(width: 16)
            default:
                HStack(spacing: 4) {
                    Image(systemName: status.symbol).foregroundStyle(status.tint)
                    if let badge = status.badge {
                        Text(badge).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .help(status.detail.map { "\(status.label) — \($0)" } ?? status.label)
        .accessibilityLabel(status.label)
    }
}

/// The full form: a row that states the answer in words and re-checks when tapped. For
/// screens where "is this working" is the question, rather than a footnote to an address.
struct ServiceStatusRow: View {
    let status: ServiceStatus
    var onRecheck: () -> Void

    var body: some View {
        Button(action: onRecheck) {
            HStack(spacing: 10) {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.tint)
                    .symbolEffect(.rotate, isActive: status.isChecking)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.label).foregroundStyle(.primary)
                    if let detail = status.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if !status.isChecking {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(status.isChecking)
        // One element for VoiceOver, and a stable handle for the UI test — a badge that
        // claims a connection is exactly the kind of thing that must be asserted rather
        // than admired.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ServerStatus")
        .accessibilityHint("Double tap to check the connection again")
    }
}
