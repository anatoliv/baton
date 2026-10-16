import BatonShareKit
import BatonSubsonicKit
import SwiftUI
import ImageIO
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct SharedWithYouView: View {
    let invitation: ShareInvitation
    var audioSession: IncomingShareAudioSession = .unmanaged
    let pauseLibrary: () -> Void
    let playLibrary: (NavidromeSong) -> Void
    let close: () -> Void
    @State private var model = SharedWithYouModel()
    @State private var action: Task<Void, Never>?
    @State private var name = ""
    @State private var reply = ""
    @State private var emoji = "❤️"
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let metadata = model.metadata {
                        artwork
                        Text(metadata.title).font(.title.bold())
                        if !metadata.artist.isEmpty { Text(metadata.artist).font(.title3) }
                        if !metadata.album.isEmpty { Text(metadata.album).foregroundStyle(.secondary) }
                        if !metadata.from.isEmpty { Text("Shared by \(metadata.from)") }
                        if !metadata.note.isEmpty { Text(metadata.note) }
                    }
                    content
                    if let message = model.message { Text(message).foregroundStyle(.secondary) }
                    Button("Open in browser") { openURL(invitation.browserURL) }
                        .accessibilityIdentifier("incomingShare.browser")
                }
                .padding(24).frame(maxWidth: 540, alignment: .leading).frame(maxWidth: .infinity)
            }
            .navigationTitle("Shared with you")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) } }
        }
        .task(id: invitation) { await model.load(invitation) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { action?.cancel(); action = nil; model.stop() } }
        .onChange(of: invitation) { _, _ in action?.cancel(); action = nil }
        .onDisappear { action?.cancel(); action = nil; model.clear(); name = ""; reply = "" }
        .accessibilityIdentifier("incomingShare.sheet")
    }
    @ViewBuilder private var artwork: some View {
        if let data = model.artwork,
           let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceCreateThumbnailWithTransform: true
           ] as CFDictionary) {
            Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxHeight: 260)
        }
    }
    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading: ProgressView("Opening song…")
        case .pending:
            Text("This song is still arriving. Please try again in a moment.")
            retry
        case let .failed(failure):
            Text(failureText(failure)).accessibilityIdentifier("incomingShare.failure")
            if failure == .network || failure == .unavailable { retry }
        case .ready:
            Button(model.isPlaying ? "Pause" : "Play") {
                run { await model.togglePlayback(pauseLibrary: pauseLibrary, audioSession: audioSession) }
            }.buttonStyle(.borderedProminent).disabled(model.busy)
                .accessibilityIdentifier("incomingShare.play")
            if model.duration > 0 {
                Slider(value: Binding(get: { model.position }, set: { model.seek($0) }), in: 0...max(1, model.duration))
                    .accessibilityLabel("Song position")
                Text("\(Int(model.position)) / \(Int(model.duration)) seconds").font(.caption).monospacedDigit()
            }
            Button(model.finding ? "Searching your library…" : "Find in my library") {
                run { await model.findInLibrary() }
            }.disabled(model.finding).accessibilityIdentifier("incomingShare.find")
            if let result = model.libraryResult {
                if !result.complete { Text("The search reached its limit. These results cover part of your library; an exact recording may still be elsewhere.").foregroundStyle(.secondary) }
                if result.songs.isEmpty, result.complete { Text("No matching song was found in your library.") }
                if result.songs.count > 1 { Text("Choose your copy of this song:") }
                ForEach(result.songs) { song in
                    Button {
                        action?.cancel(); model.stop(); playLibrary(song); close()
                    } label: {
                        VStack(alignment: .leading) {
                            Text("Play \(song.title) from my library")
                            Text([song.album, song.suffix, song.bitRate.map { "\($0) kbps" }, song.duration.map { "\($0) seconds" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if model.reactionSent { Text("Sent. Thank you!").accessibilityIdentifier("incomingShare.sent") }
            else if model.canReact {
                Picker("Reaction", selection: $emoji) {
                    ForEach(ShareLimits.reactions, id: \.self) { Text($0).tag($0) }
                }
                TextField("Your name (optional)", text: $name)
                TextField("Say something (optional)", text: $reply, axis: .vertical)
                Button("Send") { run { await model.react(emoji: emoji, name: name, reply: reply) } }.disabled(model.busy)
            } else { Text("Listen for 30 seconds, or to the end, to send a reaction.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var retry: some View { Button("Try again") { run { await model.load(invitation) } } }
    private func run(_ operation: @escaping @MainActor () async -> Void) {
        action?.cancel(); action = Task { await operation() }
    }
    private func failureText(_ failure: ShareReceiverClient.Failure) -> String {
        switch failure {
        case .incomplete: "This link is incomplete or its key could not unlock the song. Ask your friend to send the full link again."
        case .expired: "This link has ended. Ask your friend to share it again."
        case .capped: "This link has reached its play limit. Ask your friend to share it again."
        case .unknown: "This song link could not be found."
        case .network: "The song could not be reached. Check your connection and try again."
        case .tooLarge, .invalidData: "This song could not be opened. Ask your friend to share it again."
        case .unavailable: "The song is temporarily unavailable. Please try again."
        }
    }
}
