import AVFoundation
import BatonAgentKit
import SwiftUI

/// The music friend, on the Mac.
///
/// The phone has had this since 0.3.x and the desktop has not, which left the Mac in an odd
/// position: it has been *running* the friend for Telegram and Discord all along, recording
/// every exchange, and offering its owner no way to talk to it without opening a chat app.
///
/// **Not a port of the phone's screen.** `MusicFriendView` owns its own agent client,
/// because a phone with no Baton on it has to reach a brain somehow — over the gateway or
/// straight to a provider. The Mac already *is* the brain: `RemoteControlService` holds the
/// router, the tool surface, the memory and the model config. So this is a window onto that,
/// through `RemoteControlService.ask`, and it inherits the parser (so "pause" stays instant
/// and costs nothing), the fallback, the shared conversation log and the feedback log. A
/// second client here would be a second dialect of the same conversation.
///
/// **A window, not a Settings pane.** The friend log sits in Settings because reading back
/// over what was asked is an occasional, sit-down thing. A conversation is not: you keep it
/// open beside the library, which on this platform means its own window.
struct MacMusicFriendView: View {
    static let windowID = "music-friend"

    @Environment(RemoteControlService.self) private var remote: RemoteControlService?
    @Environment(MusicModel.self) private var music: MusicModel?

    /// Push-to-talk, shared verbatim with the phone. Built lazily so the window costs
    /// nothing until someone actually presses the mic — constructing it asks the system
    /// about speech recognition, which is not free and not needed to read a transcript.
    @State private var voice: VoiceInput?

    /// Speak replies back when the question was asked out loud, and only then.
    ///
    /// The phone's rule exactly, and the same preference key, so turning it off on one turns
    /// it off on the other. Typing a question and having the Mac talk at you is a different
    /// product; answering out loud when you spoke out loud is a conversation.
    @AppStorage("baton.agent.speakReplies") private var speakReplies = true
    @State private var lastMessageWasVoice = false
    @State private var synthesizer = AVSpeechSynthesizer()

    struct Message: Identifiable, Equatable {
        enum Role { case you, friend, status }
        let id = UUID()
        var role: Role
        var text: String
        /// The logged exchange this reply belongs to, so a rating knows what it rates.
        var exchangeID: UUID?
    }

    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var isThinking = false
    @FocusState private var composerFocused: Bool

    /// The app's appearance choice, not the system's.
    ///
    /// Caught by opening the window rather than by a test: against a dark library this came
    /// up white, because a new window follows the system unless told otherwise. `MusicView`
    /// already carries the note that Settings and Help drifting to the system was the bug
    /// worth fixing — one control, one answer. This is chrome, so it follows the setting;
    /// player surfaces stay dark regardless and are not this.
    @AppStorage(AppearanceSetting.key) private var appearanceRaw = AppearanceSetting.dark.rawValue
    private var appearance: AppearanceSetting {
        AppearanceSetting(rawValue: appearanceRaw) ?? .dark
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .frame(minWidth: 420, minHeight: 320)
        .batonAppearance(appearance)
        .onAppear {
            composerFocused = true
            // Catch the replies nobody asked for: an auto-picked choice lands well after the
            // question was answered, and without this the music starts with nothing in the
            // transcript to explain it.
            remote?.desktopSink = { reply in
                messages.append(Message(role: .friend, text: reply.text,
                                        exchangeID: remote?.feedbackLog.exchanges.first { $0.surface == .mac }?.id))
            }
        }
        .onDisappear { remote?.desktopSink = nil }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty { emptyState }
                    ForEach(messages) { message in
                        MacFriendBubble(message: message,
                                        rate: rateAction(for: message),
                                        recordedRating: recordedRating(for: message))
                            .id(message.id)
                    }
                    if isThinking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(.horizontal, 4)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages) { _, new in
                if let last = new.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask for music.")
                .font(.title3.weight(.semibold))
            Text("""
            The same friend that answers on Telegram and Discord, with your library and this \
            Mac's player as its hands. Plain commands like “pause” or “next” are handled \
            without spending a model call.
            """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if case .denied(let why)? = voice?.state {
                Label(why, systemImage: "mic.slash")
                    .font(.callout)
                    .foregroundStyle(Color.warningTint)
                    .padding(.top, 4)
            }
            if !isConfigured {
                Label("Set a model provider in Settings → Remote Control before it can answer.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Color.warningTint)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Return sends, Option-Return breaks the line — the desktop convention, and the
            // reason this is a TextField with `axis: .vertical` rather than a TextEditor,
            // which would swallow Return as a newline and leave no way to send from the
            // keyboard at all.
            TextField("Ask for music…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($composerFocused)
                .onSubmit(send)
                .disabled(isThinking)
                .accessibilityIdentifier("FriendComposerField")

            Button(action: toggleMic) {
                Image(systemName: voice?.isListening == true ? "mic.fill" : "mic")
                    .font(.title3)
                    .foregroundStyle(voice?.isListening == true ? Color.red : Color.batonOrange)
            }
            .buttonStyle(.plain)
            .disabled(isThinking)
            .help(voice?.isListening == true ? "Stop and send what you said" : "Hold a thought — click to talk")
            .accessibilityLabel(voice?.isListening == true ? "Stop listening" : "Speak")

            // A way out of here. This window is the one place in the app where someone can
            // be genuinely stuck — nothing answers, and the reason (no model provider) is
            // not something the window can fix for them. Every other feature is reachable
            // from a menu that sits next to Help; a window with its own scene is not.
            HelpTopicButton(topicSlug: "the-music-friend", label: "About the music friend")

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || isThinking)
            .help("Send (Return)")
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Behaviour

    private var isConfigured: Bool {
        remote?.settings.naturalLanguage.isEnabled == true
    }

    /// What this answer was already rated, read back from the log so a reopened window shows
    /// it. Without this the thumbs reset every time and a rating looked like it never took.
    private func recordedRating(for message: Message) -> FriendExchange.Rating? {
        guard let id = message.exchangeID, let remote else { return nil }
        return remote.feedbackLog.exchanges.first { $0.id == id }?.rating
    }

    private func rateAction(for message: Message)
    -> ((FriendExchange.Rating, FriendExchange.Fault?, String?) -> Void)? {
        guard message.role == .friend, let id = message.exchangeID, let remote else { return nil }
        return { rating, fault, note in
            remote.feedbackLog.rate(id, rating, fault: fault, note: note)
        }
    }

    /// Click to start listening, click again to stop and send what was heard.
    ///
    /// The same gesture as the phone's, deliberately. A hold-to-talk button would be more
    /// natural with a mouse and would then be a second thing to learn for anyone who uses
    /// both — and the transcript arriving as you speak already tells you it is listening.
    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }

    private func toggleMic() {
        guard let music else { return }
        let input = voice ?? VoiceInput(controller: music.music)
        voice = input
        if input.isListening {
            let heard = input.stop()
            guard !heard.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            draft = heard
            lastMessageWasVoice = true
            send()
        } else {
            Task { await input.start() }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        let spoken = lastMessageWasVoice
        lastMessageWasVoice = false
        draft = ""
        messages.append(Message(role: .you, text: text))
        guard let remote else {
            messages.append(Message(role: .status, text: "The music friend isn't available."))
            return
        }
        isThinking = true
        Task {
            let reply = await remote.ask(text)
            isThinking = false
            guard let reply else {
                // The router returns nil for a message it deliberately ignores. Saying so is
                // better than an empty bubble that looks like a failure.
                messages.append(Message(role: .status, text: "Nothing to do with that one."))
                return
            }
            messages.append(Message(
                role: .friend,
                text: reply.text,
                // The router already recorded this exchange — unlike the phone, which builds
                // and records its own because it owns the client. So this reads the entry
                // back rather than writing a second one: `record` inserts newest-first, so
                // the first `.mac` entry is the answer that just arrived.
                exchangeID: remote.feedbackLog.exchanges.first { $0.surface == .mac }?.id
            ))
            if spoken, speakReplies { speak(reply.text) }
        }
    }
}

/// One line of the conversation, with the quiet rating controls the phone uses.
///
/// Deliberately the same shape as `MessageBubble` on iOS — bubbles on opposite sides, thumbs
/// that appear only under an answer and only once there is something to rate. Matching it
/// matters more than being clever: this is one product, and someone moving between the two
/// should not have to learn a second idea of what a conversation looks like.
private struct MacFriendBubble: View {
    let message: MacMusicFriendView.Message
    var rate: ((FriendExchange.Rating, FriendExchange.Fault?, String?) -> Void)?

    /// Seeded from the log rather than starting nil.
    ///
    /// A rating used to live only in this view's state, so it vanished the moment the window
    /// closed — you could rate the same answer twice and the transcript would never admit
    /// you had rated it at all. The log is where the rating actually lives; this reads it.
    @State private var rating: FriendExchange.Rating?
    @State private var showsFaultPicker = false
    /// The recorded rating for this message, if there is one.
    var recordedRating: FriendExchange.Rating?

    var body: some View {
        VStack(alignment: message.role == .you ? .trailing : .leading, spacing: 4) {
            HStack {
                if message.role == .you { Spacer(minLength: 64) }
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(background, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(message.role == .you ? Color.white : .primary)
                    .font(message.role == .status ? .callout : .body)
                    .fixedSize(horizontal: false, vertical: true)
                if message.role != .you { Spacer(minLength: 64) }
            }
            if message.role == .friend, rate != nil { ratingControls }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .you ? .trailing : .leading)
        .onAppear { rating = rating ?? recordedRating }
    }

    private var ratingControls: some View {
        HStack(spacing: 12) {
            Button {
                rating = .up
                rate?(.up, nil, nil)
            } label: {
                Image(systemName: rating == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            .help("This was right")

            Button {
                rating = .down
                showsFaultPicker = true
            } label: {
                Image(systemName: rating == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
            .help("This was wrong")
            .popover(isPresented: $showsFaultPicker) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What went wrong?").font(.callout.weight(.semibold))
                    ForEach(FriendExchange.Fault.allCases, id: \.self) { fault in
                        Button(fault.label) {
                            rate?(.down, fault, nil)
                            showsFaultPicker = false
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(rating == nil ? .secondary : Color.batonOrange)
        .padding(.horizontal, 4)
    }

    private var background: AnyShapeStyle {
        switch message.role {
        case .you: AnyShapeStyle(Color.batonOrange)
        case .friend: AnyShapeStyle(.quaternary)
        case .status: AnyShapeStyle(.quinary)
        }
    }
}
