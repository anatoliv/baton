import AVFoundation
import BatonShareKit
import BatonSubsonicKit
import Foundation
import Observation

/// A received key, decrypted metadata and audio live only for this presentation. Nothing is
/// written to the share ledger, preferences, URL cache, logs or temporary audio files.
@MainActor @Observable
final class SharedWithYouModel {
    enum State: Equatable { case loading, pending, ready, failed(ShareReceiverClient.Failure) }
    private(set) var state: State = .loading
    private(set) var metadata: ShareMetadata?
    private(set) var artwork: Data?
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var canReact = false
    private(set) var reactionSent = false
    private(set) var busy = false
    var message: String?
    var libraryResult: SharedSongFinder.Result?
    var finding = false
    private var generation = UUID()
    private var invitation: ShareInvitation?
    private var details: ShareReceiverClient.Details?
    private var player: AVAudioPlayer?
    private var audioDelegate: SharedAudioDelegate?
    private var playbackTask: Task<Void, Never>?
    private var eventTasks: [Task<Void, Never>] = []
    private let clock = ContinuousClock()
    private var lastTick: ContinuousClock.Instant?
    private var releaseAudioSession: (@MainActor () -> Void)?
    private var listening = SharedSongListening()
    private let client: ShareReceiverClient
    init(client: ShareReceiverClient? = nil) {
        // Both inputs are locally constructed canonical or isolated-loopback bases.
        self.client = client ?? ((try? ShareReceiverClient(base: SongSharing.defaultBase)) ?? (try! ShareReceiverClient()))
    }

    func load(_ invitation: ShareInvitation) async {
        clear()
        self.invitation = invitation
        let token = generation
        state = .loading
        do {
            #if os(iOS)
            let platform = "ios"
            #else
            let platform = "macos"
            #endif
            for attempt in 0..<15 {
                try check(token)
                let fetched = try await client.details(invitation, platform: platform, reportOpen: attempt == 0)
                try check(token)
                details = fetched
                metadata = fetched.metadata
                if fetched.share.status == .ready {
                    state = .ready
                    if fetched.share.hasArt {
                        let bytes = try? await client.artwork(invitation, encrypted: fetched.share.preview == nil)
                        try check(token)
                        artwork = bytes
                    }
                    return
                }
                state = .pending
                if attempt < 14 { try await Task.sleep(for: .seconds(2)) }
            }
        } catch is CancellationError { return }
        catch let failure as ShareReceiverClient.Failure {
            guard token == generation else { return }; clear(); state = .failed(failure)
        }
        catch { guard token == generation else { return }; clear(); state = .failed(.unavailable) }
    }
    func togglePlayback(pauseLibrary: () -> Void, audioSession: IncomingShareAudioSession) async {
        guard !busy, let invitation, let details, state == .ready else { return }
        if let player {
            if player.isPlaying { stop() }
            else {
                do {
                    pauseLibrary()
                    try activate(audioSession)
                    guard player.play() else { throw ShareReceiverClient.Failure.unavailable }
                    isPlaying = true
                    resetListeningClock()
                } catch { stop(); message = "Audio could not start. Please try again." }
            }
            return
        }
        let token = generation
        busy = true
        defer { if token == generation { busy = false } }
        do {
            let bytes = try await client.audio(invitation, expectedBytes: details.share.audioBytes)
            try check(token)
            let prepared = try AVAudioPlayer(data: bytes)
            guard prepared.duration.isFinite, prepared.duration > 0,
                  prepared.duration <= Double(ShareLimits.standard.maxDurationSeconds) + 1 else {
                throw ShareReceiverClient.Failure.invalidData
            }
            let delegate = SharedAudioDelegate { [weak self] success in
                guard let self, token == self.generation else { return }
                self.finished(success)
            }
            audioDelegate = delegate
            prepared.delegate = delegate
            prepared.prepareToPlay()
            pauseLibrary()
            try activate(audioSession)
            guard prepared.play() else { throw ShareReceiverClient.Failure.unavailable }
            player = prepared
            duration = prepared.duration
            isPlaying = true
            resetListeningClock()
            playbackTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self, token == self.generation else { return }
                    await self.tick()
                }
            }
        } catch is CancellationError { return }
        catch let failure as ShareReceiverClient.Failure {
            guard token == generation else { return }; clear(); state = .failed(failure)
        }
        catch {
            guard token == generation else { return }
            stop()
            audioDelegate = nil
            message = "This song could not be played. Try opening it in your browser."
        }
    }
    func seek(_ value: Double) {
        guard let player, value.isFinite else { return }
        player.currentTime = min(max(0, value), duration)
        position = player.currentTime
        resetListeningClock()
    }
    private func tick() async {
        guard let player, let invitation else { return }
        position = player.currentTime
        isPlaying = player.isPlaying
        let now = clock.now
        let elapsed = lastTick.map { $0.duration(to: now) }
        lastTick = now
        let components = elapsed?.components
        let seconds = components.map { Double($0.seconds) + Double($0.attoseconds) / 1e18 } ?? 0
        let events = listening.observe(position: position, wallSeconds: seconds, playing: isPlaying)
        send(events, invitation: invitation)
        if listening.seconds >= 30 { canReact = true }
    }
    private func finished(_ success: Bool) {
        isPlaying = false
        lastTick = nil
        releaseSession()
        if success { position = duration; canReact = true }
        let events = listening.finished(successfully: success)
        guard let invitation else { return }
        send(events, invitation: invitation)
        if !success { state = .failed(.invalidData) }
    }
    private func send(_ events: [PlayerEvent.Kind], invitation: ShareInvitation) {
        guard !events.isEmpty else { return }
        eventTasks.append(Task { [client] in
            for event in events {
                guard !Task.isCancelled else { return }
                await client.event(invitation.id, PlayerEvent(type: event))
            }
        })
    }
    func react(emoji: String, name: String, reply: String) async {
        guard canReact, !reactionSent, !busy, let invitation else { return }
        let token = generation
        busy = true
        defer { if token == generation { busy = false } }
        do {
            try await client.react(invitation.id, reaction: ReactionRequest(emoji: emoji, name: name, reply: reply))
            try check(token)
            reactionSent = true
        } catch is CancellationError { return }
        catch { guard token == generation else { return }; message = "Your reply could not be sent. Please try again." }
    }
    func findInLibrary() async {
        guard let metadata, !finding else { return }
        guard NavidromeConfig.isConfigured else {
            message = "Connect Baton to your music server to find your own copy of this song."
            return
        }
        let token = generation
        finding = true
        defer { if token == generation { finding = false } }
        do {
            let result = try await NavidromeConfig.makeClient().findSharedSong(
                title: metadata.title, artist: metadata.artist, recordingID: metadata.recordingID)
            try check(token)
            libraryResult = result
            if result.complete, let invitation {
                await client.event(invitation.id, PlayerEvent(type: .foundInLibrary, found: !result.songs.isEmpty))
            }
        } catch is CancellationError { return }
        catch { guard token == generation else { return }; message = "Your library could not be searched. Check your connection and try again." }
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }
    private func activate(_ session: IncomingShareAudioSession) throws {
        releaseSession()
        let token = generation
        releaseAudioSession = try session.activate { [weak self] event in
            guard let self, token == self.generation else { return }
            self.stop()
            if event == .mediaServicesReset {
                self.playbackTask?.cancel(); self.playbackTask = nil
                self.player?.stop(); self.player = nil; self.audioDelegate = nil
                self.position = 0; self.duration = 0
                self.message = "Audio was reset. Tap Play to reload the song."
            }
        }
    }
    private func releaseSession() {
        let release = releaseAudioSession
        releaseAudioSession = nil
        release?()
    }
    private func resetListeningClock() {
        listening.resetPosition()
        if let player {
            _ = listening.observe(position: player.currentTime, wallSeconds: 0, playing: false)
        }
        lastTick = isPlaying ? clock.now : nil
    }
    func stop() {
        player?.pause(); isPlaying = false
        listening.resetPosition(); lastTick = nil
        releaseSession()
    }
    func clear() {
        generation = UUID()
        releaseSession(); lastTick = nil
        playbackTask?.cancel(); playbackTask = nil
        eventTasks.forEach { $0.cancel() }; eventTasks.removeAll()
        player?.stop(); player = nil; audioDelegate = nil
        invitation = nil; details = nil; metadata = nil; artwork = nil
        libraryResult = nil; message = nil
        position = 0; duration = 0; isPlaying = false; canReact = false; reactionSent = false
        busy = false; finding = false
        listening = SharedSongListening()
    }
}

@MainActor
private final class SharedAudioDelegate: NSObject, AVAudioPlayerDelegate {
    private let completed: (Bool) -> Void
    init(_ completed: @escaping (Bool) -> Void) { self.completed = completed }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.completed(flag) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.completed(false) }
    }
}
