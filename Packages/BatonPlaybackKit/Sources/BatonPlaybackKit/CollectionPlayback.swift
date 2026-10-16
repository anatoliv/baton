import Foundation

/// What a collection's own Play button should say and do: the one rule both apps use to
/// decide whether an album, playlist, artist, folder, show, mix or list is *the one loaded
/// in the player*.
///
/// Every screen used to answer that for itself, or not at all. The iPhone album screen's
/// big "Play" button never changed while the album played and pressing it started the
/// album again from track one; Mac cards showed Pause while playing but Play again once
/// paused, and that Play restarted the list instead of resuming it. The owner's report:
/// "the play button does not change and does not work properly".
///
/// The rule, in order:
/// 1. The player's `queueSource` must name the same collection. Kind and id decide it; a
///    source with no id (Liked, Downloads, a radio built on the fly) is matched by kind
///    and label, since that is all either side has.
/// 2. The track the player holds must still be one the collection loaded. When the queue
///    has run past the collection (continuation, Play Next, Add to Queue), the music is no
///    longer that collection, so its button goes back to Play. Radio sources are open
///    ended by nature, so whatever the station appended still counts as the station.
/// 3. Parked at the end of its last track (the queue ran out) also reads as Play: pressing
///    it should start the collection again, not replay the final second.
///
/// A track of the album played from somewhere else (search, history, a single song) is
/// not the album playing: its source is that other place, so rule 1 says no.
public enum CollectionPlayState: Equatable, Sendable {
    /// Not the collection loaded in the player: the button starts it.
    case idle
    /// Loaded and playing (or buffering towards playing): the button pauses.
    case playing
    /// Loaded and paused: the button resumes where it stopped.
    case paused

    /// The button's title, also its VoiceOver label.
    public var title: String {
        switch self {
        case .idle: "Play"
        case .playing: "Pause"
        case .paused: "Resume"
        }
    }

    /// The SF Symbol for the button. Play and Resume share the triangle; the morph to the
    /// pause bars is what tells the two states apart at a glance.
    public var symbol: String {
        switch self {
        case .idle, .paused: "play.fill"
        case .playing: "pause.fill"
        }
    }

    /// The collection is the one in the player, playing or not (the "selected" cue).
    public var isLoaded: Bool { self != .idle }

    /// The pure rule. Every input is something the player already exposes, so the tests
    /// can state each case without audio.
    /// - Parameters:
    ///   - collection: the source this screen or card would play.
    ///   - loaded: the player's `queueSource`.
    ///   - nowPlayingID: the id of the track the player holds, if any.
    ///   - memberIDs: the ids the collection loaded into the queue, or nil when unknown
    ///     (a queue restored from a build that did not record them): then any track counts.
    ///   - playerState: the player's state.
    ///   - atEnd: the player is parked at the end of the queue's last track.
    public static func resolve(
        collection: StreamingPlaybackController.QueueSource,
        loaded: StreamingPlaybackController.QueueSource?,
        nowPlayingID: String?,
        memberIDs: Set<String>?,
        playerState: StreamingPlaybackController.State,
        atEnd: Bool
    ) -> CollectionPlayState {
        guard let loaded, loaded.isSameCollection(as: collection), let nowPlayingID else { return .idle }
        if collection.kind != .radio, let memberIDs, !memberIDs.contains(nowPlayingID) { return .idle }
        switch playerState {
        case .playing, .loading:
            return .playing
        case .paused, .idle, .error:
            // `.idle` with a track is a Stop that kept the queue; at the end it is a queue
            // that ran out. Only the first is something to resume.
            return atEnd ? .idle : .paused
        }
    }
}

extension StreamingPlaybackController.QueueSource {
    /// Whether two sources name the same collection: same kind, and the same id when either
    /// has one. With no id on either side, the label is all there is to go on.
    public func isSameCollection(as other: Self) -> Bool {
        guard kind == other.kind else { return false }
        if id != nil || other.id != nil { return id == other.id }
        return label == other.label
    }
}

extension StreamingPlaybackController {
    /// Where `source` stands in the player right now. Observation-tracked, so a view that
    /// reads it redraws when playback starts, pauses or moves on.
    public func collectionState(_ source: QueueSource) -> CollectionPlayState {
        CollectionPlayState.resolve(
            collection: source,
            loaded: queueSource,
            nowPlayingID: nowPlaying?.id,
            memberIDs: queueSourceSongIDs,
            playerState: state,
            // Only the queue's last track can have "run out"; a pause that happens to sit on
            // the final second of track two is still a pause.
            atEnd: currentIndex == queue.count - 1
                && TrackBoundary.isAtEnd(currentTime: currentTime, duration: duration)
        )
    }

    /// The collection Play button's action when the collection is already loaded: pause it
    /// while playing, resume it while paused. Returns false when it is not loaded, and the
    /// caller then starts it (fetching its songs first if it has to).
    ///
    ///     if !model.music.toggleIfLoaded(source) { play() }
    @discardableResult
    public func toggleIfLoaded(_ source: QueueSource) -> Bool {
        switch collectionState(source) {
        case .playing: pause(); return true
        case .paused: resume(); return true
        case .idle: return false
        }
    }
}

// MARK: - Pins (Later)

extension PinnedItem {
    /// The pin as a queue source, named the way its own screen names it, so a pinned album
    /// is the same album as on the Albums screen. Every pin used to play as a
    /// playlist, so a pinned album never lit up and "Playing from" looked for a playlist
    /// that was not there.
    public var queueSource: StreamingPlaybackController.QueueSource {
        let kind: StreamingPlaybackController.QueueSource.Kind = switch self.kind {
        case .album: .album
        case .artist: .artist
        case .playlist, .podcastChannel: .playlist   // a show plays as its show page does
        case .song, .podcastEpisode, .radioStation: .song
        }
        return .init(label: title, kind: kind, id: refID)
    }
}

extension CollectionPlayState {
    /// What a pin's play control shows. A single song or episode is that track wherever it
    /// was started from; a station is on the air or not (a live stream has no paused place
    /// to resume); a collection follows the rule above.
    @MainActor
    public static func of(pin: PinnedItem, player: StreamingPlaybackController,
                          radio: InternetRadioStore) -> CollectionPlayState {
        switch pin.kind {
        case .song, .podcastEpisode:
            guard player.nowPlaying?.id == pin.refID else { return .idle }
            return player.isPlaying || player.state == .loading ? .playing : .paused
        case .radioStation:
            guard let station = radio.stations.first(where: { $0.id == pin.refID }) else { return .idle }
            return radio.isPlaying(station) ? .playing : .idle
        case .album, .artist, .playlist, .podcastChannel:
            return player.collectionState(pin.queueSource)
        }
    }

    /// A pin's play control when the pin is already in the player: pause or resume it (a
    /// station stops). Returns false when the caller should start it.
    @MainActor
    @discardableResult
    public static func toggleIfLoaded(pin: PinnedItem, player: StreamingPlaybackController,
                                      radio: InternetRadioStore) -> Bool {
        switch (pin.kind, of(pin: pin, player: player, radio: radio)) {
        case (.radioStation, .playing): radio.stop(); return true
        case (_, .playing): player.pause(); return true
        case (_, .paused): player.resume(); return true
        case (_, .idle): return false
        }
    }
}
