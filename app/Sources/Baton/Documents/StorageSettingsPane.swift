import BatonDocuments
import SwiftUI

/// Settings → Storage (M6.4, `specs/document-clippings.md`, *Storage*): the books on this Mac
/// with their sizes, the books on the home server from its own listing (`GET /v1/books`) with
/// their sizes and keep dates, the cleanup rules, and the week of Recently removed.
///
/// One screen for the whole question "what is taking space and what will happen to it", so
/// nothing is removed in a way the person could not have seen coming.
struct BatonStoragePane: View {
    @Environment(MusicModel.self) private var model

    @State private var listing: GatewayBookClient.Listing?
    @State private var askingServer = false
    @State private var serverProblem: String?
    @State private var restoreProblem: String?

    private var library: DocumentLibrary { model.documents }

    var body: some View {
        Form {
            if model.documentsSwitch.isOn {
                thisMacSection
                homeServerSection
                rulesSection
                recentlyRemovedSection
            } else {
                Section("Books") {
                    Text("Documents are off on this Mac. Turn them on in Settings, under Speech, to make books and keep them here.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            guard model.documentsSwitch.isOn else { return }
            library.refresh()
            library.cleanup.purge()
            await askServer()
        }
    }

    // MARK: - This Mac

    private var thisMacSection: some View {
        let books = library.storedBooks
        let total = books.reduce(0) { $0 + $1.bytes }
        let free = BookCleanup.freeBytes(at: URL(fileURLWithPath: NSHomeDirectory()))
        return Section {
            if books.isEmpty {
                Text("No books on this Mac yet. Choose File, Import Document to make one.").foregroundStyle(.secondary)
            }
            ForEach(books) { book in
                deviceRow(book)
            }
        } header: {
            Text("This Mac")
        } footer: {
            Text(Self.deviceFooter(count: books.count, bytes: total, free: free, device: "this Mac"))
        }
    }

    /// "3 books, 120 MB. 45 GB free on this Mac."
    static func deviceFooter(count: Int, bytes: Int, free: Int?, device: String) -> String {
        let books = count == 1 ? "1 book" : "\(count) books"
        let freeText = free.map { " \(BookStorage.sizeText($0)) free on \(device)." } ?? ""
        return "\(books), \(BookStorage.sizeText(bytes)).\(freeText)"
    }

    /// "Finished · Made on this Mac", said plainly.
    static func statusText(_ book: StoredBook, madeHere: Bool) -> String {
        var parts: [String] = []
        if book.isOffloaded {
            parts.append("Download removed")
        } else if book.inProgress {
            parts.append("Listening")
        } else if book.finishedAt != nil {
            parts.append("Finished")
        } else {
            parts.append("Not started")
        }
        parts.append(madeHere ? "Made on this Mac" : "Made on the home server")
        if !book.canGetBack { parts.append("The only copy, so no rule removes it") }
        return parts.joined(separator: " · ")
    }

    private func deviceRow(_ book: StoredBook) -> some View {
        let shelfBook = library.shelf.first { $0.documentID == book.documentID }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).lineLimit(1)
                Text(Self.statusText(book, madeHere: book.homeServerJobID == nil))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(book.isOffloaded ? "" : BookStorage.sizeText(book.bytes))
                .monospacedDigit().foregroundStyle(.secondary)
            if let shelfBook, let title = library.getBackTitle(shelfBook) {
                Button(title) {
                    Task { try? await library.getBack(shelfBook) }
                }
            } else if let shelfBook, !book.present.isEmpty, book.canGetBack {
                Button("Remove Download") { library.offload(shelfBook) }
            }
            Toggle("Keep", isOn: Binding(
                get: { library.cleanup.isKept(book.documentID) },
                set: { library.cleanup.setKeep($0, documentID: book.documentID) }
            ))
            .toggleStyle(.checkbox)
            .help("A book marked Keep is never removed by a rule or a suggestion.")
        }
    }

    // MARK: - The home server

    private var homeServerSection: some View {
        Section {
            if !library.homeServer.isConfigured {
                Text("No home server is set up, so every book is made and kept on this Mac.")
                    .foregroundStyle(.secondary)
            } else if let listing {
                if listing.books.isEmpty {
                    Text("The home server has no books.").foregroundStyle(.secondary)
                }
                ForEach(listing.books, id: \.id) { summary in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.title).lineLimit(1)
                            Text(Self.serverStatusText(summary)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(BookStorage.sizeText(summary.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } else if askingServer {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking the home server…") }
            } else {
                Text("The home server could not be asked: \(serverProblem ?? "it isn't answering").")
                    .foregroundStyle(.orange)
            }
        } header: {
            HStack {
                Text("Home Server")
                Spacer()
                if library.homeServer.isConfigured {
                    Button("Refresh") { Task { await askServer() } }.disabled(askingServer)
                }
            }
        } footer: {
            if let listing { Text(Self.serverFooter(listing)) }
        }
    }

    /// "Using 300 MB of 4 GB. Finished books are kept there for 30 days, and a book you
    /// have not finished is never removed."
    static func serverFooter(_ listing: GatewayBookClient.Listing) -> String {
        var text = "Using \(BookStorage.sizeText(listing.usedBytes))"
        if listing.maximumBytes > 0 { text += " of \(BookStorage.sizeText(listing.maximumBytes))" }
        text += "."
        if listing.keepFinishedDays > 0 {
            text += " Finished books are kept there for \(listing.keepFinishedDays) days, and a book you have not finished is never removed."
        }
        if !listing.available, let reason = listing.unavailableReason { text += " Books are off there: \(reason)." }
        return text
    }

    /// "Kept until 2 November", or what the home server is doing with it.
    static func serverStatusText(_ summary: BookJob.Summary) -> String {
        if let removesAt = summary.removesAt { return "Finished · " + BookShelf.keptUntilText(removesAt) }
        switch summary.status {
        case .rendering: return "Being made"
        case .paused: return "Paused" + (summary.pauseReason.map { ": \($0)" } ?? "")
        case .failed: return "Stopped"
        case .ready: return "Ready"
        }
    }

    private func askServer() async {
        guard library.homeServer.isConfigured else { return }
        askingServer = true
        listing = await library.homeServer.listing()
        serverProblem = library.homeServer.problem
        askingServer = false
    }

    // MARK: - Rules

    private var rulesSection: some View {
        Section {
            Picker("After I finish a book", selection: choice(StoragePolicy.Rules.afterFinishedChoices, \.afterFinished)) {
                ForEach(StoragePolicy.Rules.afterFinishedChoices.indices, id: \.self) { index in
                    Text(StoragePolicy.Rules.afterFinishedChoices[index].0).tag(index)
                }
            }
            Picker("Books I haven't played", selection: choice(StoragePolicy.Rules.unplayedChoices, \.unplayedFor)) {
                ForEach(StoragePolicy.Rules.unplayedChoices.indices, id: \.self) { index in
                    Text(StoragePolicy.Rules.unplayedChoices[index].0).tag(index)
                }
            }
            Picker("Space for books on this Mac", selection: choice(StoragePolicy.Rules.spaceChoices, \.spaceLimit)) {
                ForEach(StoragePolicy.Rules.spaceChoices.indices, id: \.self) { index in
                    Text(StoragePolicy.Rules.spaceChoices[index].0).tag(index)
                }
            }
        } header: {
            Text("Cleanup")
        } footer: {
            Text(Self.rulesFooter)
        }
    }

    static let rulesFooter = "Nothing is removed until you choose a rule here. A rule removes a book's download, "
        + "never the book: its words, its voice and your place stay, and Download Again brings it back. "
        + "The book you are listening to and books marked Keep are never removed. These rules are for this Mac only."

    /// A picker's index for one rule, read from and written to this Mac's settings.
    private func choice<Value: Equatable>(_ choices: [(String, Value)],
                                          _ rule: WritableKeyPath<StoragePolicy.Rules, Value>) -> Binding<Int> {
        Binding(
            get: { choices.firstIndex { $0.1 == library.cleanup.rules[keyPath: rule] } ?? 0 },
            set: { index in
                var rules = library.cleanup.rules
                rules[keyPath: rule] = choices[index].1
                library.cleanup.setRules(rules)
                library.applyStorageRules()
            }
        )
    }

    // MARK: - Recently removed

    private var recentlyRemovedSection: some View {
        Section {
            if library.cleanup.removed.isEmpty {
                Text("Nothing was removed in the last week.").foregroundStyle(.secondary)
            }
            ForEach(library.cleanup.removed) { entry in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).lineLimit(1)
                        Text(BookStorage.removedText(entry, now: Date(), device: "this Mac"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    switch entry.kind {
                    case .deleted:
                        Button("Restore") {
                            do { try library.restore(entry); restoreProblem = nil } catch {
                                restoreProblem = "\(entry.title) could not be restored: \(error.localizedDescription)"
                            }
                        }
                        Button("Delete Now", role: .destructive) { library.cleanup.purgeNow(entry) }
                    case .offloaded:
                        if let book = library.shelf.first(where: { $0.documentID == entry.documentID }),
                           let title = library.getBackTitle(book) {
                            Button(title) { Task { try? await library.getBack(book) } }
                        }
                    }
                }
            }
            if let restoreProblem { Text(restoreProblem).foregroundStyle(.orange) }
        } header: {
            Text("Recently Removed")
        } footer: {
            Text("Removed downloads and deleted books are listed here for a week. A deleted book's audio "
                 + "is kept until then, so Restore brings it back as it was.")
        }
    }
}
