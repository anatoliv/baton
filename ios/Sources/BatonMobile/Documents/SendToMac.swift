import BatonPlaybackKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What the import screen offers when it cannot make the book itself.
///
/// - The home server makes books: Make Audiobook, as before.
/// - It answered but cannot make books (no voice server, books off, a gateway from before books):
///   **Send to my Mac**, through the gateway's file store, for Baton on the Mac to import.
/// - No home server at all: **AirDrop** the original to the Mac, through the share sheet.
/// - A home server that does not answer: say why, and suggest AirDrop, since nothing can travel
///   through a gateway that is away.
enum ImportOffer: Equatable {
    case asking
    case makeAudiobook
    case sendToMac
    case airDrop
    case unreachable

    init(_ availability: HomeServerBooks.Availability?) {
        switch availability {
        case nil: self = .asking
        case .available?: self = .makeAudiobook
        case .cannotMakeBooks?: self = .sendToMac
        case .notConfigured?: self = .airDrop
        case .unreachable?: self = .unreachable
        }
    }

    /// Whether the AirDrop suggestion is shown.
    var suggestsAirDrop: Bool { self == .airDrop || self == .unreachable }
}

/// Sending the original document to the Mac through the gateway.
@MainActor
enum SendToMac {
    /// The file or link the phone was given, parked for the Mac. A link travels as the address;
    /// the Mac reads the page itself.
    @discardableResult
    static func send(_ source: URL, title: String, through relay: PendingImportRelay,
                     fromDevice: String) async throws -> PendingImport {
        if MobileDocuments.isWebLink(source) {
            return try await relay.send(link: source, title: title, fromDevice: fromDevice)
        }
        return try await relay.send(file: source, title: title, contentType: contentType(for: source),
                                    fromDevice: fromDevice)
    }

    static func contentType(for file: URL) -> String {
        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// A failed send, in the screen's words.
    static func failureText(_ error: Error) -> String {
        if case let .rejected(status, _)? = error as? GatewayFiles.TransferError, status == 413 {
            return "The file is too big to send through your Baton server. AirDrop it to your Mac instead."
        }
        return "It could not be sent: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
    }
}

extension MobileModel {
    /// "Send to my Mac" through the gateway Settings configures. Nil until address and token are set.
    func pendingImportRelay(session: URLSession = .shared) -> PendingImportRelay? {
        guard case let (url, token)? = bearerGateway() else { return nil }
        return PendingImportRelay(files: GatewayFiles(gatewayURL: url, token: token, session: session))
    }
}

/// The import screen's last section when the book cannot be made from the phone.
struct SendToMacSection: View {
    let offer: ImportOffer
    /// The original file or link, as the phone was given it.
    let source: URL
    let title: String
    let problem: String?
    let model: MobileModel
    let onDone: () -> Void

    @State private var sending = false
    @State private var sent = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Making a book needs your Baton server", systemImage: "server.rack")
            Text(explanation).font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("needs-home-server")

        if offer == .sendToMac {
            if sent {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Sent to your Mac", systemImage: "checkmark.circle")
                    Text("Baton on your Mac opens it to import, the next time it is open there with Documents on.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sent-to-mac")
                Button("Done", action: onDone)
            } else {
                Button {
                    send()
                } label: {
                    HStack {
                        Spacer()
                        if sending { ProgressView().controlSize(.small).padding(.trailing, 6) }
                        Text("Send to my Mac").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(sending)
                .accessibilityIdentifier("send-to-mac")
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(.orange)
                }
            }
        }

        if offer.suggestsAirDrop {
            ShareLink(item: source) {
                Label(MobileDocuments.isWebLink(source) ? "AirDrop the Link to Your Mac" : "AirDrop the File to Your Mac",
                      systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("airdrop-to-mac")
        }
    }

    private var explanation: String {
        // The reason is a phrase, but a system error's own text ends with a full stop.
        let problem = problem.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        switch offer {
        case .sendToMac:
            let why = problem.map { "It cannot make books right now: \($0)." } ?? "It cannot make books right now."
            return "\(why) Send this to your Mac instead, and make the book there."
        case .airDrop:
            return "No Baton server is set up (Settings, Music Friend, Baton server). To make the book on your Mac, AirDrop this to it and open it in Baton."
        case .unreachable:
            let why = problem.map { "It is not available: \($0)." } ?? "It is not available."
            return "\(why) You can AirDrop this to your Mac and make the book there."
        case .asking, .makeAudiobook:
            return ""
        }
    }

    private func send() {
        guard let relay = model.pendingImportRelay() else {
            failure = "Set up your Baton server under Settings first."
            return
        }
        sending = true
        failure = nil
        Task {
            do {
                try await SendToMac.send(source, title: title, through: relay, fromDevice: UIDevice.current.name)
                sent = true
            } catch {
                failure = SendToMac.failureText(error)
            }
            sending = false
        }
    }
}
