import BatonShareKit
import BatonSubsonicKit
import SwiftUI

struct SharedMixtapeView: View {
    let invitation: ShareInvitation
    var audioSession: IncomingShareAudioSession = .unmanaged
    let pauseLibrary: () -> Void
    let playLibrary: (NavidromeSong) -> Void
    let close: () -> Void
    @State private var model = SharedMixtapeModel()
    @State private var action: Task<Void, Never>?
    @State private var emoji = "❤️"
    @State private var name = ""
    @State private var reply = ""
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let manifest = model.manifest {
                        Text(manifest.title).font(.title.bold()).accessibilityIdentifier("incomingMixtape.title")
                        ForEach(Array(manifest.tracks.enumerated()), id: \.element.id) { index, track in
                            Button {
                                run { await model.select(index, pauseLibrary: pauseLibrary, audioSession: audioSession) }
                            } label: {
                                HStack {
                                    Image(systemName: index == model.selectedIndex ? "music.note" : "circle")
                                    VStack(alignment: .leading) {
                                        Text("\(index + 1). \(track.metadata.title)")
                                        Text(track.metadata.artist).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.accessibilityIdentifier("incomingMixtape.track.\(index)")
                        }
                    }
                    content
                    if let message = model.message { Text(message).foregroundStyle(.secondary) }
                    Button("Open in browser") { openURL(invitation.browserURL) }.accessibilityIdentifier("incomingMixtape.browser")
                }.padding(24).frame(maxWidth: 540, alignment: .leading).frame(maxWidth: .infinity)
            }
            .navigationTitle("Shared mixtape")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) } }
        }
        .task(id: invitation) { await model.load(invitation) }
        .onChange(of: invitation) { _, _ in action?.cancel(); action = nil }
        .onChange(of: scenePhase) { _, phase in
            action?.cancel(); action = nil
            if phase == .active { run { await model.load(invitation) } }
            else { model.clear(); name = ""; reply = "" }
        }
        .onDisappear { action?.cancel(); action = nil; model.clear(); name = ""; reply = "" }
        .alert("Use another play?", isPresented: Binding(get: { model.needsAnotherPlay }, set: { _ in })) {
            Button("Cancel", role: .cancel) { model.cancelAnotherPlay() }
            Button("Use Another Play") { run { await model.confirmAnotherPlay(pauseLibrary: pauseLibrary, audioSession: audioSession) } }
        } message: {
            Text("This track needs a new listening allowance. Starting it uses one more play from this link. Pause, resume and seeking in the current loaded track do not use another play.")
        }
        .accessibilityIdentifier("incomingMixtape.sheet")
    }
    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading: ProgressView("Opening mixtape…")
        case .pending: Text("This mixtape is still arriving."); retry
        case let .failed(failure):
            Text(SharedMixtapeModel.failureText(failure)).accessibilityIdentifier("incomingMixtape.failure")
            if failure == .network || failure == .unavailable { retry }
        case .ready:
            if let metadata = model.metadata {
                Text(metadata.title).font(.headline)
                if !metadata.from.isEmpty { Text("Shared by \(metadata.from)") }
                if !metadata.note.isEmpty { Text(metadata.note) }
            }
            HStack {
                Button("Previous") { run { await model.select(model.selectedIndex - 1, pauseLibrary: pauseLibrary, audioSession: audioSession) } }
                    .disabled(model.selectedIndex == 0).accessibilityIdentifier("incomingMixtape.previous")
                Button(model.isPlaying ? "Pause" : "Play") {
                    run { await model.togglePlayback(pauseLibrary: pauseLibrary, audioSession: audioSession) }
                }.buttonStyle(.borderedProminent).disabled(model.busy || model.needsAnotherPlay)
                    .accessibilityIdentifier("incomingMixtape.play")
                Button("Next") { run { await model.select(model.selectedIndex + 1, pauseLibrary: pauseLibrary, audioSession: audioSession) } }
                    .disabled(model.selectedIndex + 1 >= (model.manifest?.tracks.count ?? 0)).accessibilityIdentifier("incomingMixtape.next")
            }
            if model.busy { ProgressView("Loading this track…") }
            if model.duration > 0 {
                Slider(value: Binding(get: { model.position }, set: { model.seek($0) }), in: 0...max(model.duration, 1))
                    .accessibilityLabel("Track position").accessibilityIdentifier("incomingMixtape.seek")
                Text("\(Int(model.position)) / \(Int(model.duration)) seconds").font(.caption.monospacedDigit())
                    .accessibilityIdentifier("incomingMixtape.clock")
            }
            Button(model.finding ? "Searching your library…" : "Find this track in my library") { run { await model.findInLibrary() } }
                .disabled(model.finding).accessibilityIdentifier("incomingMixtape.find")
            if let result = model.libraryResult {
                if !result.complete { Text("These results cover part of your library. An exact recording may still be elsewhere.").foregroundStyle(.secondary) }
                if result.complete && result.songs.isEmpty { Text("No matching track was found in your library.") }
                if result.songs.count > 1 { Text("Choose your copy of this track:") }
                ForEach(result.songs) { song in
                    Button {
                        action?.cancel(); model.clear(); playLibrary(song); close()
                    } label: {
                        VStack(alignment: .leading) {
                            Text("Play \(song.title) from my library")
                            Text([song.album, song.suffix, song.bitRate.map { "\($0) kbps" }, song.duration.map { "\($0) seconds" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if model.reactionSent { Text("Sent. Thank you!").accessibilityIdentifier("incomingMixtape.sent") }
            else if model.canReact {
                Picker("Reaction", selection: $emoji) { ForEach(ShareLimits.reactions, id: \.self) { Text($0).tag($0) } }
                TextField("Your name (optional)", text: $name)
                TextField("Say something (optional)", text: $reply, axis: .vertical)
                Button("Send") { run { await model.react(emoji: emoji, name: name, reply: reply) } }.disabled(model.busy)
            } else { Text("Listen for 30 seconds, or to the end of a track, to send a reaction.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var retry: some View { Button("Try again") { run { await model.load(invitation) } } }
    private func run(_ operation: @escaping @MainActor () async -> Void) { action?.cancel(); action = Task { await operation() } }
}

/// Both platform presenters retain their existing scene/window ownership fence.
struct IncomingSharedContent: View {
    let invitation: ShareInvitation
    var audioSession: IncomingShareAudioSession = .unmanaged
    let pauseLibrary: () -> Void
    let playLibrary: (NavidromeSong) -> Void
    let close: () -> Void
    var body: some View {
        if invitation.kind == .mixtape {
            SharedMixtapeView(invitation: invitation, audioSession: audioSession, pauseLibrary: pauseLibrary, playLibrary: playLibrary, close: close)
        } else {
            SharedWithYouView(invitation: invitation, audioSession: audioSession, pauseLibrary: pauseLibrary, playLibrary: playLibrary, close: close)
        }
    }
}
