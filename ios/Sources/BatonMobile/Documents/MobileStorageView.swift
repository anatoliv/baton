import BatonDocuments
import SwiftUI

/// Settings → Storage on the phone (M6.4, `specs/document-clippings.md`, *Storage*): the books
/// on this iPhone with their sizes, the home server's own listing (`GET /v1/books`) with sizes
/// and keep dates, the cleanup rules, and the week of Recently removed. The Mac's
/// `BatonStoragePane` says the same things in the same words; the logic under both is
/// `BookCleanup` and `StoragePolicy`.
struct MobileStorageView: View {
    let model: MobileModel

    @State private var listing: GatewayBookClient.Listing?
    @State private var askingServer = false
    @State private var serverProblem: String?
    @State private var restoreProblem: String?

    private var cleanup: BookCleanup { model.bookCleanup }

    var body: some View {
        Form {
            thisPhoneSection
            homeServerSection
            rulesSection
            recentlyRemovedSection
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await askServer() }
        .task {
            cleanup.purge()
            await askServer()
        }
    }

    // MARK: - This iPhone

    private var thisPhoneSection: some View {
        let books = model.shelfBooks
        let stored = books.map(model.stored)
        let total = stored.reduce(0) { $0 + $1.bytes }
        return Section {
            if books.isEmpty {
                Text("No books on this iPhone yet. Import one from Clippings, Files or the share sheet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(zip(books, stored)), id: \.0.documentID) { book, item in
                bookRow(book, item)
            }
        } header: {
            Text("This iPhone")
        } footer: {
            Text(Self.deviceFooter(count: books.count, bytes: total, free: model.freeBytes))
        }
    }

    /// "3 books, 120 MB. 45 GB free on this iPhone."
    static func deviceFooter(count: Int, bytes: Int, free: Int?) -> String {
        let books = count == 1 ? "1 book" : "\(count) books"
        let freeText = free.map { " \(BookStorage.sizeText($0)) free on this iPhone." } ?? ""
        return "\(books), \(BookStorage.sizeText(bytes)).\(freeText)"
    }

    static func statusText(_ book: StoredBook) -> String {
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
        if book.isOffloaded == false { parts.append(BookStorage.sizeText(book.bytes)) }
        if !book.canGetBack { parts.append("The only copy, so no rule removes it") }
        return parts.joined(separator: " · ")
    }

    private func bookRow(_ book: MobileBookShelf.Book, _ item: StoredBook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(book.title).lineLimit(1)
            Text(Self.statusText(item)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 8) {
                if let title = model.getBackTitle(book) {
                    Button(title) { Task { try? await model.getBack(book) } }
                        .buttonStyle(.bordered)
                } else if !item.present.isEmpty, item.canGetBack {
                    Button("Remove Download") { model.offload(book) }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Toggle("Keep", isOn: Binding(
                    get: { cleanup.isKept(book.documentID) },
                    set: { cleanup.setKeep($0, documentID: book.documentID) }
                ))
                .fixedSize()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    // MARK: - The home server

    private var homeServerSection: some View {
        Section {
            if !model.books.isConfigured {
                Text("No home server is set up. Books are made on your home server, so set one up in Settings first.")
                    .foregroundStyle(.secondary)
            } else if let listing {
                if listing.books.isEmpty {
                    Text("The home server has no books.").foregroundStyle(.secondary)
                }
                ForEach(listing.books, id: \.id) { summary in
                    LabeledContent {
                        Text(BookStorage.sizeText(summary.bytes)).monospacedDigit()
                    } label: {
                        Text(summary.title).lineLimit(1)
                        Text(Self.serverStatusText(summary))
                    }
                }
            } else if askingServer {
                HStack(spacing: 8) { ProgressView(); Text("Asking the home server…") }
            } else {
                Text("The home server could not be asked: \(serverProblem ?? "it isn't answering").")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Home Server")
        } footer: {
            if let listing { Text(Self.serverFooter(listing)) }
        }
    }

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

    static func serverStatusText(_ summary: BookJob.Summary) -> String {
        if let removesAt = summary.removesAt { return "Finished · " + keptUntilText(removesAt) }
        switch summary.status {
        case .rendering: return "Being made"
        case .paused: return "Paused" + (summary.pauseReason.map { ": \($0)" } ?? "")
        case .failed: return "Stopped"
        case .ready: return "Ready"
        }
    }

    /// "Kept until 2 November", with the year once it is not this one: the Mac's wording.
    static func keptUntilText(_ date: Date, now: Date = Date()) -> String {
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        let style: Date.FormatStyle = sameYear ? .dateTime.day().month(.wide) : .dateTime.day().month(.wide).year()
        return "Kept until \(date.formatted(style))"
    }

    private func askServer() async {
        guard model.books.isConfigured else { return }
        askingServer = true
        listing = await model.books.listing()
        serverProblem = model.books.problem
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
            Picker("Space for books", selection: choice(StoragePolicy.Rules.spaceChoices, \.spaceLimit)) {
                ForEach(StoragePolicy.Rules.spaceChoices.indices, id: \.self) { index in
                    Text(StoragePolicy.Rules.spaceChoices[index].0).tag(index)
                }
            }
        } header: {
            Text("Cleanup")
        } footer: {
            Text("Nothing is removed until you choose a rule here. A rule removes a book's download, never the book: "
                 + "its words, its voice and your place stay, and Download Again brings it back. The book you are "
                 + "listening to and books marked Keep are never removed. These rules are for this iPhone only.")
        }
    }

    private func choice<Value: Equatable>(_ choices: [(String, Value)],
                                          _ rule: WritableKeyPath<StoragePolicy.Rules, Value>) -> Binding<Int> {
        Binding(
            get: { choices.firstIndex { $0.1 == cleanup.rules[keyPath: rule] } ?? 0 },
            set: { index in
                var rules = cleanup.rules
                rules[keyPath: rule] = choices[index].1
                cleanup.setRules(rules)
                model.applyStorageRules()
            }
        )
    }

    // MARK: - Recently removed

    private var recentlyRemovedSection: some View {
        Section {
            if cleanup.removed.isEmpty {
                Text("Nothing was removed in the last week.").foregroundStyle(.secondary)
            }
            ForEach(cleanup.removed) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.title).lineLimit(1)
                    Text(BookStorage.removedText(entry, now: Date(), device: "this iPhone"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        switch entry.kind {
                        case .deleted:
                            Button("Restore") {
                                do { try cleanup.restore(entry); restoreProblem = nil } catch {
                                    restoreProblem = "\(entry.title) could not be restored: \(error.localizedDescription)"
                                }
                            }
                            .buttonStyle(.bordered)
                            Button("Delete Now", role: .destructive) { cleanup.purgeNow(entry) }
                                .buttonStyle(.bordered)
                        case .offloaded:
                            if let book = model.shelfBooks.first(where: { $0.documentID == entry.documentID }),
                               let title = model.getBackTitle(book) {
                                Button(title) { Task { try? await model.getBack(book) } }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
            if let restoreProblem { Text(restoreProblem).foregroundStyle(.orange) }
        } header: {
            Text("Recently Removed")
        } footer: {
            Text("Removed downloads and deleted books are listed here for a week. A deleted book's audio is kept "
                 + "until then, so Restore brings it back as it was.")
        }
    }
}
