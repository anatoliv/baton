import BatonAgentKit
import SwiftUI

/// What the music friend was asked over Telegram and Discord, on the Mac.
///
/// The Mac has been *recording* these all along — `RemoteControlService` owns a
/// `FriendFeedbackLog` and hands it to the router, so every chat-bridge exchange has been
/// written down since the log shipped. What it never had was a way to look at any of it, or
/// to say one was wrong. So the loop ran open on the desktop: the data accumulated, and the
/// half that makes it useful — a person disagreeing with it — existed only on the phone.
///
/// This is the smaller, denser sibling of the phone's `FriendLogView`, in a settings pane
/// rather than a sheet, because on a desktop this is something you sit down and read rather
/// than something you check.
struct MacFriendLogView: View {
    @Environment(RemoteControlService.self) private var remote: RemoteControlService?

    @State private var filter: FriendExchange.Fault?
    @State private var showsClearConfirm = false
    /// The exchange whose "what should it have done?" note is being typed.
    @State private var noting: FriendExchange?
    @State private var noteText = ""

    private var log: FriendFeedbackLog? { remote?.feedbackLog }
    private var learning: FriendLearningStore? { remote?.learning }
    private var memory: RemoteMemoryStore? { remote?.memory }

    private var shown: [FriendExchange] {
        guard let log else { return [] }
        guard let filter else { return log.exchanges }
        return log.exchanges.filter { $0.fault == filter }
    }

    var body: some View {
        Form {
            // Memories first, and outside the "are there exchanges" branch below.
            //
            // Outside, because the two are not the same question. Clearing the log leaves the
            // memories standing, so a pane that only drew them when the log had rows would
            // hide, behind an empty log, the sentences the app is still sending to a model.
            // First, because this is the section the 0.18.0 What's New sent people here to
            // find, and it is the one with something personal in it.
            if let memory, !memory.entries.isEmpty { remembered(memory) }
            if let log, !log.exchanges.isEmpty {
                tally(log)
                if let learning, !learning.corrections.isEmpty { learned(learning) }
                exchanges
                Section {
                    Button("Clear Log", role: .destructive) { showsClearConfirm = true }
                }
            } else if memory?.entries.isEmpty ?? true {
                Section {
                    Text("Nothing yet. Ask the music friend something over Telegram or "
                         + "Discord and it will show up here, with a way to tell it when it "
                         + "got something wrong.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear the friend log?", isPresented: $showsClearConfirm) {
            Button("Clear", role: .destructive) { log?.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every recorded exchange. What it has already learned is kept — "
                 + "remove those separately, so clearing a log does not silently undo "
                 + "corrections you meant.")
        }
        .sheet(item: $noting) { exchange in
            noteSheet(for: exchange)
        }
    }

    @ViewBuilder
    private func tally(_ log: FriendFeedbackLog) -> some View {
        if !log.faultTally.isEmpty {
            Section("What goes wrong") {
                ForEach(log.faultTally, id: \.fault) { entry in
                    Button {
                        filter = (filter == entry.fault) ? nil : entry.fault
                    } label: {
                        HStack {
                            Label(entry.fault.label,
                                  systemImage: filter == entry.fault ? "checkmark.circle.fill" : "circle")
                            Spacer()
                            Text("\(entry.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                }
                Text("Click to show only those. The fault matters more than the count — each "
                     + "one points at a different fix.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// What the friend believes about the person it is talking to.
    ///
    /// The Mac had none of this. `RemoteMemoryStore` had exactly one surface in the whole tree
    /// and it was the phone's `FriendLogView`; on the desktop the store was reachable only from
    /// the chat router, so preferences and facts about someone were stored, sent to a model to
    /// steer its answers, and never shown to the person they were about. The 0.18.0 What's New
    /// card said "There is a screen for it too, so you can read what it has learned and remove
    /// anything you would rather it forgot" — true on the phone, false here, which is the worst
    /// kind of half right.
    ///
    /// Deliberately not the same section as "What it has learned" below. Corrections are the
    /// friend's inferences from a thumbs-down; these are the person's own sentences. Merging
    /// them would put a guess and a quote under one heading.
    @ViewBuilder
    private func remembered(_ memory: RemoteMemoryStore) -> some View {
        Section("What it remembers") {
            ForEach(memory.entries) { entry in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.text).font(.callout)
                        // The quote, not a paraphrase. It is what makes a wrong memory
                        // correctable rather than merely deniable: you can see the sentence it
                        // was drawn from and judge the leap.
                        Text("You said: “\(entry.quote)”")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    // Through the store's own forget, which lays a tombstone as it saves.
                    // Removing the row any other way would bring the memory straight back on
                    // the next sync, because an absence is indistinguishable from never having
                    // heard of it.
                    Button("Forget") { memory.forget(id: entry.id) }
                        .buttonStyle(.borderless)
                }
            }
            Text("Things you told the friend about yourself, in your own words. Forgetting one "
                 + "removes it from your other devices too. Settings, Remote has the switch "
                 + "that stops it remembering anything new, and a button to delete the lot.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func learned(_ learning: FriendLearningStore) -> some View {
        Section("What it has learned") {
            ForEach(learning.corrections) { correction in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("“\(correction.request)”").font(.callout)
                        Text(correction.note.map { "You said: \($0)" } ?? correction.fault.label)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget") { learning.forget(correction.id) }
                        .buttonStyle(.borderless)
                }
            }
            // The point of showing these is that they can be wrong: one thumbs-down given
            // in irritation is indistinguishable, to the machine, from a considered one.
            Text("Added to what the friend is told about you, as evidence rather than rules. "
                 + "A learned correction you cannot see is one you cannot fix.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var exchanges: some View {
        Section(filter.map { "\($0.label)" } ?? "Recent") {
            ForEach(shown) { exchange in
                VStack(alignment: .leading, spacing: 4) {
                    Text(exchange.request).font(.callout.weight(.medium))
                    Text(exchange.reply).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    HStack(spacing: 8) {
                        Text(exchange.surface.rawValue)
                        Text("·")
                        Text(exchange.resolution)
                        if exchange.skippedQuickly {
                            Text("· skipped at once").foregroundStyle(Color.warningTint)
                        }
                        Spacer()
                        rating(for: exchange)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func rating(for exchange: FriendExchange) -> some View {
        HStack(spacing: 10) {
            Button {
                rate(exchange, .up, fault: nil)
            } label: {
                Image(systemName: exchange.rating == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            .buttonStyle(.borderless)
            .help("Good answer")

            Menu {
                ForEach(FriendExchange.Fault.allCases, id: \.self) { fault in
                    Button(fault.label) { rate(exchange, .down, fault: fault) }
                }
                Button("Just wrong") { rate(exchange, .down, fault: nil) }
            } label: {
                Image(systemName: exchange.rating == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Poor answer")
        }
        .foregroundStyle(exchange.rating == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
    }

    /// Records the rating, then asks what it should have done — for the two faults where
    /// that answer is what turns a complaint into a test. Same rule as the phone, and the
    /// rating is written first so a dismissed prompt never costs it.
    private func rate(_ exchange: FriendExchange, _ rating: FriendExchange.Rating,
                      fault: FriendExchange.Fault?) {
        guard let log, let learning else { return }
        _ = log.rate(exchange.id, rating, fault: fault)
        if let updated = log.exchanges.first(where: { $0.id == exchange.id }) {
            learning.learn(from: updated)
            learning.retireIfApproved(updated)
        }
        if rating == .down, fault?.hasObservableExpectation == true {
            noteText = ""
            noting = exchange
        }
    }

    private func noteSheet(for exchange: FriendExchange) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should it have done?").font(.headline)
            Text("Optional. What you meant is the one thing the log cannot work out on its own.")
                .font(.callout).foregroundStyle(.secondary)
            Text("“\(exchange.request)”").font(.callout.italic()).foregroundStyle(.secondary)
            TextField("In your own words", text: $noteText, axis: .vertical)
                .lineLimit(2 ... 5)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Skip") { noting = nil }
                Button("Save") {
                    let typed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !typed.isEmpty, let log {
                        _ = log.rate(exchange.id, .down, fault: exchange.fault, note: typed)
                        if let updated = log.exchanges.first(where: { $0.id == exchange.id }) {
                            learning?.learn(from: updated)
                        }
                    }
                    noting = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
