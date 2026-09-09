import BatonAgentKit
import SwiftUI

/// Everything the music friend has been asked, what it did about it, and how it was rated.
///
/// A log you can read is the point. A rating that only feeds a hidden average tells you
/// nothing when the friend gets worse, and gives you no way to see *why* it was wrong —
/// which is almost always visible in the arguments it sent rather than in the words it
/// said back.
struct FriendLogView: View {
    let log: FriendFeedbackLog
    let learning: FriendLearningStore
    let memory: RemoteMemoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var filter: FriendExchange.Fault?
    @State private var showsClearConfirm = false

    private var exportable: String {
        FriendEvalExport.swiftCases(from: log.exchanges)
    }

    private var shown: [FriendExchange] {
        guard let filter else { return log.exchanges }
        return log.exchanges.filter { $0.fault == filter }
    }

    var body: some View {
        NavigationStack {
            List {
                if !log.faultTally.isEmpty {
                    Section {
                        // What goes wrong most, first — the shape that answers "what should
                        // I fix next" rather than "how is it doing".
                        ForEach(log.faultTally, id: \.fault) { entry in
                            Button {
                                filter = (filter == entry.fault) ? nil : entry.fault
                            } label: {
                                HStack {
                                    Label(entry.fault.label, systemImage: filter == entry.fault ? "checkmark.circle.fill" : "circle")
                                    Spacer()
                                    Text("\(entry.count)").foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    } header: {
                        Text("What goes wrong")
                    } footer: {
                        Text("Tap to show only those. The fault matters more than the count: each one points at a different fix.")
                    }
                }

                // What the friend believes about the person it is talking to.
                //
                // This had no surface on the phone at all: `friendMemory` appeared five
                // times in `ios/Sources/BatonMobile` and every one was in `MobileModel`. So
                // preferences and facts about someone — "nothing loud before nine", "their
                // partner is called Sam" — were stored, sent to a model to steer its
                // answers, and never shown to the person they were about. Corrections got a
                // swipe-to-delete; memories got nothing.
                //
                // It is also the only way a memory bug is observable here. Since these
                // cross devices, a memory that fails to arrive, arrives twice, or comes
                // back after a forget could otherwise only be diagnosed by pulling a JSON
                // file out of the simulator's container — and this repo's own experience is
                // that sync defects are invisible to a green suite and obvious on a screen.
                if !memory.entries.isEmpty {
                    Section {
                        ForEach(memory.entries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.text).font(.callout)
                                // The quote, not a paraphrase. It is what makes a wrong
                                // memory correctable rather than merely deniable: you can
                                // see the sentence it was drawn from and judge the leap.
                                Text("You said: “\(entry.quote)”")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { offsets in
                            // Through the store's own forget, which lays a tombstone as it
                            // saves. A memory removed by deleting the row some other way
                            // would come straight back on the next sync, because an absence
                            // is indistinguishable from never having heard of it.
                            offsets.map { memory.entries[$0].id }.forEach { memory.forget(id: $0) }
                        }
                    } header: {
                        Text("What it remembers")
                    } footer: {
                        Text("Things you told the friend about yourself, in your own words. Swipe to forget one. It is removed from your other devices too.")
                    }
                }

                if !learning.corrections.isEmpty {
                    Section {
                        ForEach(learning.corrections) { correction in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("“\(correction.request)”").font(.callout)
                                Text(correction.note.map { "You said: \($0)" } ?? correction.fault.label)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { learning.corrections[$0].id }.forEach(learning.forget)
                        }
                    } header: {
                        Text("What it has learned")
                    } footer: {
                        // The point of showing these is that they can be wrong. One
                        // thumbs-down given in irritation is indistinguishable, to the
                        // machine, from a considered one.
                        Text("Added to what the friend is told about you, as evidence rather than rules. Swipe to remove one: a learned correction you cannot see is one you cannot fix.")
                    }
                }

                Section(shown.isEmpty ? "Nothing yet" : "Conversations") {
                    ForEach(shown) { exchange in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(exchange.request).font(.body).lineLimit(3)
                                Spacer(minLength: 8)
                                if let rating = exchange.rating {
                                    Image(systemName: rating == .up ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                                        .font(.caption)
                                        .foregroundStyle(rating == .up ? Color.green : Color.orange)
                                }
                            }
                            // What it *did*, which is the part worth keeping: "played the
                            // wrong thing" cannot be acted on a fortnight later, while
                            // "music_search with a query nobody would type" can.
                            Text(exchange.resolution)
                                .font(.caption).foregroundStyle(.secondary)
                            // Skipped at once is the most common way a wrong track shows
                            // itself — far more common than anyone bothering to rate it.
                            if exchange.skippedQuickly {
                                Label("skipped straight away", systemImage: "forward.end")
                                    .font(.caption2).foregroundStyle(Color.warningTint)
                            }
                            // What it was looking at when it chose. The question behind
                            // every wrong track is whether the right answer was on the list.
                            if let search = exchange.actions.first(where: { !$0.candidates.isEmpty }) {
                                Text(search.candidates)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(4)
                            }
                            if let note = exchange.note, !note.isEmpty {
                                Text("“\(note)”").font(.caption).italic().foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                Text(exchange.date.formatted(date: .abbreviated, time: .shortened))
                                Text(exchange.surface.rawValue)
                                if exchange.latency > 0 {
                                    Text(String(format: "%.1fs", exchange.latency)).monospacedDigit()
                                }
                                if let fault = exchange.fault { Text(fault.label) }
                            }
                            .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Friend Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { showsClearConfirm = true }
                        .disabled(log.exchanges.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    // Turns the answers you marked wrong into cases for the conversation
                    // eval, which runs against a real model on every release. A tuned
                    // prompt fixes today's answer; a test is what notices when the same
                    // failure comes back in a month.
                    if !exportable.isEmpty {
                        ShareLink(item: exportable) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Export as test cases")
                    }
                }
            }
            .confirmationDialog("Clear the log?", isPresented: $showsClearConfirm, titleVisibility: .visible) {
                Button("Clear everything", role: .destructive) { log.clear(); filter = nil }
            } message: {
                Text("This deletes every recorded conversation and rating on this device.")
            }
        }
    }
}

extension String {
    /// Empty is not a prompt block; nil is.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
