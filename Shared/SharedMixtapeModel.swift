import AVFoundation
import BatonShareKit
import BatonSubsonicKit
import Foundation
import Observation

/// Container/session authority outlives an individual track, but never this presentation.
/// Only the current authenticated track has a player/plaintext buffer. Nothing is persisted.
@MainActor @Observable
final class SharedMixtapeModel {
    enum State: Equatable { case loading, pending, ready, failed(ShareMixtapeReceiver.Failure) }
    private(set) var state: State = .loading
    private(set) var manifest: ShareMixtapeManifest?
    private(set) var selectedIndex = 0
    private(set) var isPlaying = false
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var busy = false
    private(set) var needsAnotherPlay = false
    private(set) var canReact = false
    private(set) var reactionSent = false
    var message: String?
    var libraryResult: SharedSongFinder.Result?
    var finding = false
    var metadata: ShareMetadata? { manifest?.tracks.indices.contains(selectedIndex) == true ? manifest?.tracks[selectedIndex].metadata : nil }
    private let client: ShareMixtapeReceiver
    private var invitation: ShareInvitation?
    private var details: ShareMixtapeReceiver.Details?
    private var session: MixtapeSession?
    // An interrupted admission may already have spent a cap unit. Its uncertainty
    // survives per-track cancellation until the listener explicitly confirms renewal.
    private var admissionMayBeSpent = false
    private var remainingBytes = 0
    private var generation = UUID()
    private var trackGeneration = UUID()
    private var player: AVAudioPlayer?
    private var audioDelegate: MixtapeAudioDelegate?
    private var releaseAudioSession: (@MainActor () -> Void)?
    private var ticker: Task<Void, Never>?
    private var detailsTask: Task<ShareMixtapeReceiver.Details, Error>?
    private var admissionTask: Task<MixtapeSession, Error>?
    private var audioTask: Task<Data, Error>?
    private var eventTasks = [Task<Void, Never>]()
    private var listening = SharedSongListening()
    private var completedTracks = Set<String>()
    private let clock = ContinuousClock()
    private var lastTick: ContinuousClock.Instant?
    init(client: ShareMixtapeReceiver? = nil) {
        self.client = client ?? ((try? ShareMixtapeReceiver(base: SongSharing.defaultBase)) ?? (try! ShareMixtapeReceiver()))
    }
    func load(_ invitation: ShareInvitation) async {
        clear(); self.invitation = invitation
        let token = generation
        do {
            for attempt in 0..<15 {
                let request = Task { [client] in try await client.details(invitation) }
                detailsTask = request
                let fetched = try await request.value
                try check(token)
                detailsTask = nil; details = fetched; manifest = fetched.manifest
                if fetched.share.status == .ready { state = .ready; return }
                state = .pending
                if attempt < 14 { try await Task.sleep(for: .seconds(2)) }
            }
        } catch is CancellationError { return }
        catch let error as ShareMixtapeReceiver.Failure {
            guard token == generation else { return }; clear(); state = .failed(error)
        } catch { guard token == generation else { return }; clear(); state = .failed(.unavailable) }
    }
    func select(_ index: Int, pauseLibrary: () -> Void, audioSession: IncomingShareAudioSession) async {
        guard manifest?.tracks.indices.contains(index) == true, index != selectedIndex else { return }
        let continuePlaying = isPlaying
        evictTrack(); selectedIndex = index; libraryResult = nil; message = nil; needsAnotherPlay = false
        if continuePlaying { await togglePlayback(pauseLibrary: pauseLibrary, audioSession: audioSession) }
    }
    func togglePlayback(pauseLibrary: () -> Void, audioSession: IncomingShareAudioSession) async {
        guard state == .ready, !busy, !needsAnotherPlay, let invitation, let details else { return }
        if let player {
            if player.isPlaying { stop() }
            else {
                do {
                    pauseLibrary(); try activate(audioSession)
                    guard player.play() else { throw ShareMixtapeReceiver.Failure.unavailable }
                    isPlaying = true; resetClock()
                } catch { stop(); message = "Audio could not start. Please try again." }
            }
            return
        }
        let token = generation, trackToken = trackGeneration, track = details.manifest.tracks[selectedIndex]
        busy = true
        defer { if token == generation && trackToken == trackGeneration { busy = false } }
        do {
            if session == nil {
                guard !admissionMayBeSpent else { needsAnotherPlay = true; return }
                admissionMayBeSpent = true
                let request = Task { [client] in try await client.admit(invitation, details: details) }
                admissionTask = request
                let admitted = try await request.value
                try check(token, trackToken)
                admissionTask = nil; session = admitted; remainingBytes = admitted.remainingBytes
                // Listening qualification, replies and completion belong to this
                // accepted allowance, independently of the previous session.
                canReact = false; reactionSent = false
                listening = SharedSongListening(); completedTracks.removeAll()
                admissionMayBeSpent = false
            }
            guard let session else { throw ShareMixtapeReceiver.Failure.sessionRequired }
            guard (ShareDate.date(session.expiresAt) ?? .distantPast) > Date(), remainingBytes >= track.audioBytes else {
                needsAnotherPlay = true; return
            }
            // Cancellation and unknown delivery results remain charged conservatively.
            // A retry can ask for another allowance, but never admits one by itself.
            remainingBytes -= track.audioBytes
            let request = Task { [client] in try await client.audio(invitation, details: details, trackID: track.id, session: session) }
            audioTask = request
            let audio = try await request.value
            try check(token, trackToken)
            audioTask = nil
            let prepared = try AVAudioPlayer(data: audio)
            guard prepared.duration.isFinite, prepared.duration > 0,
                  prepared.duration <= Double(ShareLimits.standard.maxDurationSeconds) + 1 else { throw ShareMixtapeReceiver.Failure.invalidData }
            let delegate = MixtapeAudioDelegate { [weak self] success in
                guard let self, token == self.generation, trackToken == self.trackGeneration else { return }
                self.finished(success)
            }
            prepared.delegate = delegate
            pauseLibrary(); try activate(audioSession)
            guard prepared.prepareToPlay(), prepared.play() else { throw ShareMixtapeReceiver.Failure.unavailable }
            player = prepared; audioDelegate = delegate; duration = prepared.duration; isPlaying = true
            resetClock()
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self, token == self.generation, trackToken == self.trackGeneration else { return }
                    self.tick()
                }
            }
        } catch is CancellationError { return }
        catch let failure as ShareMixtapeReceiver.Failure {
            guard token == generation && trackToken == trackGeneration else { return }
            stop()
            if failure == .transferBudget || failure == .sessionRequired { needsAnotherPlay = true }
            else { message = Self.failureText(failure) }
        } catch {
            guard token == generation && trackToken == trackGeneration else { return }
            stop(); message = "This track could not be played. Try opening the mixtape in your browser."
        }
    }
    /// The confirmation names the cost. Cancel leaves the existing session untouched.
    func confirmAnotherPlay(pauseLibrary: () -> Void, audioSession: IncomingShareAudioSession) async {
        guard needsAnotherPlay, !busy else { return }
        needsAnotherPlay = false; session = nil; remainingBytes = 0; admissionMayBeSpent = false
        await togglePlayback(pauseLibrary: pauseLibrary, audioSession: audioSession)
    }
    func cancelAnotherPlay() { needsAnotherPlay = false }
    func seek(_ value: Double) {
        guard let player, value.isFinite else { return }
        player.currentTime = min(max(value, 0), duration); position = player.currentTime; resetClock()
    }
    func stop() {
        player?.pause()
        if let player { position = player.currentTime }
        isPlaying = false; lastTick = nil; listening.resetPosition(); releaseSession()
    }
    private func tick() {
        guard let player else { return }
        position = player.currentTime; isPlaying = player.isPlaying
        let now = clock.now, elapsed = lastTick.map { $0.duration(to: now).components }
        lastTick = now
        let seconds = elapsed.map { Double($0.seconds) + Double($0.attoseconds) / 1e18 } ?? 0
        send(listening.observe(position: position, wallSeconds: seconds, playing: isPlaying))
        if listening.seconds >= 30 { canReact = true }
    }
    private func finished(_ success: Bool) {
        isPlaying = false; lastTick = nil; releaseSession()
        if success {
            position = duration; canReact = true
            // Completing an individual track enables a reply, but container completion
            // is reported only after every ordered track has reached the end.
            if let manifest {
                completedTracks.insert(manifest.tracks[selectedIndex].id)
                if completedTracks.count == manifest.tracks.count { send(listening.finished(successfully: true)) }
            }
        } else { message = Self.failureText(.invalidData) }
    }
    private func resetClock() {
        listening.resetPosition()
        if let player { _ = listening.observe(position: player.currentTime, wallSeconds: 0, playing: false) }
        lastTick = isPlaying ? clock.now : nil
    }
    private func activate(_ owner: IncomingShareAudioSession) throws {
        releaseSession()
        let token = generation
        releaseAudioSession = try owner.activate { [weak self] event in
            guard let self, token == self.generation else { return }
            self.stop()
            if event == .mediaServicesReset {
                self.evictTrack(); self.message = "Audio was reset. Tap Play to reload this track."
            }
        }
    }
    private func releaseSession() { let release = releaseAudioSession; releaseAudioSession = nil; release?() }
    private func send(_ events: [PlayerEvent.Kind]) {
        guard let invitation, let session, !events.isEmpty else { return }
        eventTasks.append(Task { [client] in
            for event in events { guard !Task.isCancelled else { return }; await client.event(invitation.id, session: session, event: .init(type: event)) }
        })
    }
    func react(emoji: String, name: String, reply: String) async {
        guard canReact, !reactionSent, !busy, let invitation, let session else { return }
        let token = generation; busy = true
        defer { if token == generation { busy = false } }
        do {
            try await client.react(invitation.id, session: session, reaction: .init(emoji: emoji, name: name, reply: reply))
            try check(token); reactionSent = true
        } catch is CancellationError { return }
        catch { guard token == generation else { return }; message = "Your reply could not be sent. Please try again." }
    }
    func findInLibrary() async {
        guard let metadata, !finding else { return }
        guard NavidromeConfig.isConfigured else { message = "Connect Baton to your music server to find your own copy of this track."; return }
        let token = generation, trackToken = trackGeneration
        finding = true
        defer { if token == generation && trackToken == trackGeneration { finding = false } }
        do {
            let result = try await NavidromeConfig.makeClient().findSharedSong(title: metadata.title, artist: metadata.artist, recordingID: metadata.recordingID)
            try check(token, trackToken); libraryResult = result
            if result.complete, let invitation, let session { await client.event(invitation.id, session: session, event: .init(type: .foundInLibrary, found: !result.songs.isEmpty)) }
        } catch is CancellationError { return }
        catch { guard token == generation && trackToken == trackGeneration else { return }; message = "Your library could not be searched. Check your connection and try again." }
    }
    private func check(_ token: UUID, _ track: UUID? = nil) throws {
        try Task.checkCancellation()
        guard token == generation, track == nil || track == trackGeneration else { throw CancellationError() }
    }
    private func evictTrack() {
        trackGeneration = UUID(); ticker?.cancel(); ticker = nil
        admissionTask?.cancel(); admissionTask = nil; audioTask?.cancel(); audioTask = nil
        player?.stop(); player = nil; audioDelegate = nil; releaseSession()
        position = 0; duration = 0; isPlaying = false; busy = false; finding = false
        lastTick = nil; listening.resetPosition()
    }
    /// Backgrounding/dismissal evicts plaintext and memory-only credentials. Reopening
    /// loads only the cap-free manifest; another Play remains an explicit action.
    func clear() {
        generation = UUID(); detailsTask?.cancel(); detailsTask = nil; evictTrack(); eventTasks.forEach { $0.cancel() }; eventTasks.removeAll()
        invitation = nil; details = nil; session = nil; manifest = nil; remainingBytes = 0; selectedIndex = 0
        admissionMayBeSpent = false
        state = .loading; libraryResult = nil; message = nil; needsAnotherPlay = false
        canReact = false; reactionSent = false; listening = SharedSongListening(); completedTracks.removeAll()
    }
    static func failureText(_ failure: ShareMixtapeReceiver.Failure) -> String {
        switch failure {
        case .incomplete: "This mixtape link is incomplete. Ask your friend to send the full link again."
        case .pending: "This mixtape is still arriving. Try again in a moment."
        case .unknown: "This mixtape link could not be found."
        case .expired: "This mixtape link has ended. Ask your friend to share it again."
        case .capped: "This mixtape has reached its play limit. Ask your friend to share it again."
        case .unsupported: "This service does not support mixtape sharing yet."
        case .network, .unavailable: "The mixtape could not be reached. Check your connection and try again."
        case .tooLarge, .invalidData: "This mixtape could not be opened. Ask your friend to share it again."
        case .sessionRequired, .transferBudget: "A new listening allowance is needed. Starting it uses another play from this link."
        }
    }
}

@MainActor
private final class MixtapeAudioDelegate: NSObject, AVAudioPlayerDelegate {
    private let completed: (Bool) -> Void
    init(_ completed: @escaping (Bool) -> Void) { self.completed = completed }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { Task { @MainActor [weak self] in self?.completed(flag) } }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { Task { @MainActor [weak self] in self?.completed(false) } }
}
