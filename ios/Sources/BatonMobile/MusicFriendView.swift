import AVFoundation
import SwiftUI

/// The music friend — the headline feature no other client has. A chat with an
/// agent whose hands are the phone's own player; the mic button (VoiceInput) and
/// spoken replies make it a conversation rather than a command line.
struct MusicFriendView: View {
    let model: MobileModel

    struct Message: Identifiable, Equatable {
        enum Role { case user, friend, status }
        let id = UUID()
        var role: Role
        var text: String
        /// The logged exchange this reply belongs to, so a thumb knows what it is rating.
        var exchangeID: UUID?
    }

    @State private var messages: [Message] = []
    @State private var showsLog = false
    @State private var draft = ""
    @State private var isThinking = false
    /// Speak the friend's replies aloud when the message arrived by voice.
    @AppStorage("baton.agent.speakReplies") private var speakReplies = true
    @State private var lastMessageWasVoice = false
    @State private var synthesizer = AVSpeechSynthesizer()
    /// Whether the composer has the keyboard. Needed because there was no way to give it
    /// back: the keyboard covers the tab bar, so with no dismissal this screen had no exit
    /// at all — you could not put the keyboard away *or* leave.
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if messages.isEmpty { emptyState }
                            ForEach(messages) { message in
                                MessageBubble(message: message, rate: message.exchangeID.map { id in
                                    { rating, fault, note in
                                        model.rateFriendExchange(id, rating, fault: fault, note: note)
                                    }
                                })
                                    .id(message.id)
                            }
                            if isThinking {
                                HStack { ProgressView(); Text("Thinking…").foregroundStyle(.secondary) }
                                    .font(.caption)
                                    .padding(.horizontal)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    // Drag the transcript down to put the keyboard away — the gesture
                    // every messaging app on the phone already teaches.
                    .scrollDismissesKeyboard(.interactively)
                    // And a plain tap anywhere in the conversation, for anyone who doesn't
                    // know the drag.
                    .onTapGesture { inputFocused = false }
                    .onChange(of: messages) { _, new in
                        if let last = new.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                inputBar
            }
            .sheet(isPresented: $showsLog) { FriendLogView(log: model.friendLog, learning: model.friendLearning) }
            .rootScreenHeader("Music Friend", subtitle: modelLine) {
                // Absent rather than disabled when there is nothing to clear.
                //
                // It was `.disabled(messages.isEmpty)`, and this header's accessory does
                // not render the dimming — so on an empty conversation it looked like a
                // live control, read as an edit button, and did nothing when tapped. A
                // control that cannot respond is worse than one that is not there: the
                // first makes people doubt the app, the second tells them the truth.
                HStack(spacing: 14) {
                    Button { showsLog = true } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel("Friend log")

                    if !messages.isEmpty {
                        Button {
                            messages = []
                            model.agent.resetConversation()
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("New conversation")
                    }
                }
            }
        }
    }

    /// Which model is answering. The tab only exists once a connection test has passed,
    /// so there is always one — and knowing whether you are talking to a local model or a
    /// hosted one changes what you'd ask it.
    private var modelLine: String? {
        let name = model.agentConfig.model
        return name.isEmpty ? nil : name
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hi — I'm your music friend.")
                .font(.headline)
            Text("Try: “play something mellow”, “what's this song?”, “start a radio from this”, or “louder”. I only know your library — that's the point.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            // A safety net rather than the usual case: the tab is hidden until a
            // connection test passes, so this only shows if the configuration was
            // pulled out from under an open screen.
            if !model.agentConfig.isReady {
                Label("Set up and test a model in Settings → Music Friend first.", systemImage: "key")
                    .font(.footnote)
                    .foregroundStyle(Color.warningTint)
            }
        }
        .padding(.horizontal)
    }

    private var inputBar: some View {
        VStack(spacing: 4) {
            if case .denied(let why) = model.voice.state {
                Text(why).font(.footnote).foregroundStyle(Color.warningTint)
            }
            HStack(spacing: 10) {
                TextField(
                    model.voice.isListening ? "Listening…" : "Ask for music…",
                    text: model.voice.isListening ? .constant(model.voice.transcript) : $draft,
                    axis: .vertical
                )
                // Rounded to match everything around it — the tab bar, the mic, the send
                // button and the search fields are all capsules, and a squarer box was the
                // only shape on screen that wasn't. An earlier version kept it square to
                // say "this commits, unlike a search field", but that job is already done
                // by the send button sitting next to it; the shape doesn't need to carry it.
                //
                // A fixed radius rather than `Capsule()`, because this field grows to four
                // lines: a capsule is half its own height, so a grown composer would become
                // a stadium with enormous ends. At one line 20pt *is* the capsule; at four
                // it stays a nicely rounded box.
                .textFieldStyle(.plain)
                // No background of its own. The composer is now a capsule, and a field pill
                // inside a bar pill is two containers for one control — visibly a box
                // behind a box, with the mic and send button stranded in the gap between
                // them. The capsule *is* the field's container.
                .padding(.vertical, 4)
                .lineLimit(1 ... 4)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .disabled(model.voice.isListening)
                // Demo mode hides this whole tab, so no simulator run against the demo
                // library can render the composer — which is how two fixes to it shipped
                // unlooked-at. `LiveFriendComposerCaptureTests` photographs it against a
                // real provider, and it needs a name to find it by.
                .accessibilityIdentifier("FriendComposerField")

                Button(action: toggleMic) {
                    Image(systemName: model.voice.isListening ? "mic.fill" : "mic")
                        .font(.title2)
                        .foregroundStyle(model.voice.isListening ? Color.red : Color.accentColor)
                        .symbolEffect(.pulse, isActive: model.voice.isListening)
                }
                .disabled(isThinking)
                .accessibilityLabel(model.voice.isListening ? "Stop listening" : "Speak")

                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || isThinking || model.voice.isListening)
                // An unlabelled symbol is "arrow up circle fill" to VoiceOver and nothing
                // at all to a test.
                .accessibilityLabel("Send")
            }
        }
        // A floating capsule, like the mini player and the tab bar below it.
        //
        // This was a full-bleed `.background(.bar)` slab at a 12pt inset while the mini bar
        // sat in a capsule at 10 — so three things stacked in the same 200pt of screen, and
        // one of them ran edge to edge past the other two. The send button looked like it
        // was hanging outside the column because the shelf under it was wider than
        // everything else, not because it was misaligned.
        //
        // `bottomChromeCapsule()` carries the shared inset, so a third floating element
        // cannot introduce a third value — which is exactly how 10 and 12 diverged.
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .bottomChromeCapsule()
    }

    /// Tap to start listening; tap again to stop and send what was heard.
    private func toggleMic() {
        if model.voice.isListening {
            let heard = model.voice.stop()
            guard !heard.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            lastMessageWasVoice = true
            send(heard)
        } else {
            Task { await model.voice.start() }
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        lastMessageWasVoice = false
        send(text)
    }

    private func send(_ text: String) {
        guard !isThinking else { return }
        messages.append(Message(role: .user, text: text))
        isThinking = true
        let spoken = lastMessageWasVoice
        let askedAt = Date()
        Task {
            do {
                let reply = try await model.agent.send(text)
                // Recorded before it is shown, so the id the reply carries is the id the
                // thumbs write to. What played is read from the player rather than parsed
                // out of the answer: the answer is prose, and prose about what happened is
                // not evidence of what happened.
                let exchange = FriendExchange(
                    date: askedAt,
                    surface: .phone,
                    request: text,
                    reply: reply.text,
                    actions: reply.toolCalls,
                    // Only when a tool actually started something. Reading `nowPlaying`
                    // unconditionally logged the track that was already on as though the
                    // friend had chosen it — so asking "what is this?" recorded a pick it
                    // never made, and every wrong-track diagnosis started from a lie.
                    played: reply.startedPlayback
                        ? (model.music.nowPlaying.map { [$0.title] } ?? [])
                        : [],
                    latency: Date().timeIntervalSince(askedAt),
                    model: model.agentConfig.model
                )
                model.friendLog.record(exchange)
                messages.append(Message(role: .friend, text: reply.text, exchangeID: exchange.id))
                if spoken, speakReplies {
                    speak(reply.text)
                }
            } catch {
                messages.append(Message(role: .status, text: error.localizedDescription))
            }
            isThinking = false
        }
    }

    /// Spoken replies: the offline system voice for now; the self-hosted Kokoro
    /// voice rides the gateway integration (BatonSpeech) later.
    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }
}

private struct MessageBubble: View {
    let message: MusicFriendView.Message
    var rate: ((FriendExchange.Rating, FriendExchange.Fault?, String?) -> Void)?

    @State private var rating: FriendExchange.Rating?
    @State private var showsFaultPicker = false
    /// The fault whose note we are asking about — non-nil drives the prompt.
    @State private var noteFault: FriendExchange.Fault?
    @State private var noteText = ""

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            HStack {
                if message.role == .user { Spacer(minLength: 48) }
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(background, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(message.role == .user ? Color.white : .primary)
                    .font(message.role == .status ? .footnote : .body)
                if message.role != .user { Spacer(minLength: 48) }
            }
            // Only on answers, and only once there is something to rate against.
            //
            // Quiet by default: a pair of thumbs under every reply, at caption weight,
            // that colour in once used. Loud rating controls make a conversation feel like
            // a survey, and a survey is the thing people stop filling in.
            if message.role == .friend, message.exchangeID != nil, let rate {
                HStack(spacing: 14) {
                    Button {
                        rating = .up
                        rate(.up, nil, nil)
                    } label: {
                        Image(systemName: rating == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    .accessibilityLabel("Good answer")

                    Button {
                        rating = .down
                        showsFaultPicker = true
                    } label: {
                        Image(systemName: rating == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    }
                    .accessibilityLabel("Poor answer")
                }
                .font(.caption)
                .foregroundStyle(rating == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .confirmationDialog("What went wrong?", isPresented: $showsFaultPicker, titleVisibility: .visible) {
                    // The fault, not the severity. "Bad" cannot be acted on; "it understood
                    // me and picked the wrong track" points straight at tool arguments.
                    ForEach(FriendExchange.Fault.allCases, id: \.self) { fault in
                        Button(fault.label) {
                            // Record the rating first, unconditionally. The note is a bonus
                            // question; a dismissed prompt, a backgrounded app or a changed
                            // mind must never cost the thumbs-down that was already given.
                            rate(.down, fault, nil)
                            if fault.hasObservableExpectation { noteFault = fault }
                        }
                    }
                    Button("Just wrong", role: .cancel) { rate(.down, nil, nil) }
                }
                // Only for the faults that imply a "should have". Asking "what should it
                // have done?" about "too chatty" collects an opinion nothing can act on,
                // and every question you ask costs you answers to the next one.
                .alert("What should it have done?", isPresented: askingForNote) {
                    TextField("In your own words", text: $noteText)
                    Button("Save") {
                        let typed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Re-rate with the same fault: `rate` overwrites the note only when
                        // there is something new to say, so an empty box changes nothing.
                        if !typed.isEmpty { rate(.down, noteFault, typed) }
                        dismissNote()
                    }
                    Button("Skip", role: .cancel) { dismissNote() }
                } message: {
                    Text("Optional. What you meant is the one thing the log cannot work out on its own.")
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var askingForNote: Binding<Bool> {
        Binding(get: { noteFault != nil }, set: { if !$0 { dismissNote() } })
    }

    private func dismissNote() {
        noteText = ""
        noteFault = nil
    }

    private var background: AnyShapeStyle {
        switch message.role {
        case .user: AnyShapeStyle(Color.accentColor)
        case .friend: AnyShapeStyle(.quaternary)
        case .status: AnyShapeStyle(.quinary)
        }
    }
}
