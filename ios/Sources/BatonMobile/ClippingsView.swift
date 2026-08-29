import BatonPlaybackKit
import BatonSubsonicModels
import OSLog
import SwiftUI

private let clippingsLog = Logger(subsystem: "io.tonebox.baton", category: "Clippings")

/// **Clippings** on the phone: audio the Mac made, collected from the home gateway.
///
/// The card this came from proposed "its own small surface". That was the wrong shape and the
/// Mac proved it: a clipping's id is its own `file://` URL, which `MediaKind` calls
/// `.localFile` and `resolveStreamURL` resolves without a server, so it plays through the
/// ordinary player with the transport, the queue and the now-playing bar already attached. A
/// bespoke surface would have meant a second player path maintained forever for content that
/// needs none.
///
/// So this file is only a list. The store, the model and the playback are all shared code that
/// already existed and is already tested.
struct ClippingsView: View {
    let model: MobileModel

    @State private var collecting = false
    @State private var status: String?
    @State private var filter = ""

    private var store: ClippingStore { model.clippings }

    private var items: [ClippingStore.Item] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return store.items }
        return store.items.filter {
            $0.clipping.title.lowercased().contains(needle)
                || ($0.clipping.source?.lowercased().contains(needle) ?? false)
                || ($0.clipping.text?.lowercased().contains(needle) ?? false)
        }
    }

    /// Only what can actually be played. A queue entry whose file has gone stalls with no
    /// explanation, which is worse than a row that visibly says it is unavailable.
    private var playable: [NavidromeSong] { items.filter(\.isPresent).map(\.asSong) }

    private var source: StreamingPlaybackController.QueueSource {
        .init(label: "Clippings", kind: .liked, id: nil)
    }

    var body: some View {
        List {
            if store.items.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No clippings yet",
                        systemImage: "waveform.circle",
                        description: Text("On your Mac, read something aloud and choose "
                                          + "File → Keep Reading in Clippings. It arrives here "
                                          + "through your home gateway.")
                    )
                }
            } else {
                Section {
                    ForEach(items) { item in
                        row(item)
                    }
                    .onDelete { offsets in
                        // Deliberately not a swipe-to-delete with no confirmation elsewhere in
                        // this app's idiom: a clipping is the only copy, so the alert below says
                        // so before anything is removed.
                        pendingDelete = offsets.compactMap { items[$0].id }
                    }
                } footer: {
                    if let text = footerText { Text(text) }
                }
            }
        }
        .navigationTitle("Clippings")
        .searchable(text: $filter, prompt: "Filter clippings")
        // Pulled by hand, so say what happened: a manual pull that silently achieves nothing is
        // indistinguishable from one that failed.
        .refreshable { await collect(announcing: true) }
        .task {
            store.loadIfNeeded()
            // Collect on open rather than on a timer. Polling is the wrong shape for a
            // local-first app, and "when you look at the screen" is both the moment you care
            // and a moment you chose.
            await collect()
        }
        .toolbar {
            if !playable.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.music.play(playable, source: source)
                    } label: { Image(systemName: "play.fill") }
                        .accessibilityLabel("Play all clippings")
                }
            }
        }
        // Two outcomes, because they are genuinely different and only you know which you mean.
        // Removing it here leaves your Mac's copy alone; deleting everywhere takes the shared
        // one too, and no device will collect it again. Offering a single "Delete" would have to
        // pick one silently, and either choice is wrong half the time.
        .confirmationDialog(
            pendingDelete.count == 1 ? "Delete this clipping?" : "Delete \(pendingDelete.count) clippings?",
            isPresented: .init(get: { !pendingDelete.isEmpty },
                               set: { if !$0 { pendingDelete = [] } }),
            titleVisibility: .visible
        ) {
            Button("Remove from this iPhone", role: .destructive) {
                // Tombstoned, so it stays gone. Your Mac keeps its copy.
                for id in pendingDelete { store.remove(id: id) }
                pendingDelete = []
            }
            Button("Delete Everywhere", role: .destructive) {
                let ids = pendingDelete
                pendingDelete = []
                Task { await deleteEverywhere(ids) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("Removing it here leaves the copy on your Mac. Deleting everywhere also removes "
                 + "it from your home gateway, so no device collects it again.")
        }
        .overlay(alignment: .bottom) {
            if let status {
                Text(status)
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: status)
    }

    @State private var pendingDelete: [String] = []

    private var footerText: String? {
        guard !store.items.isEmpty else { return nil }
        let bytes = store.totalBytes
        guard bytes > 0 else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(Counted.phrase(store.items.count, "clipping")), \(size). These play with no "
            + "server and no network."
    }

    @ViewBuilder
    private func row(_ item: ClippingStore.Item) -> some View {
        Button {
            play(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.isPresent ? "waveform" : "exclamationmark.triangle")
                    .foregroundStyle(item.isPresent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.clipping.title).lineLimit(1)
                    HStack(spacing: 6) {
                        if let origin = item.clipping.source, !origin.isEmpty { Text(origin) }
                        Text(item.clipping.createdAt, style: .date)
                        if let seconds = item.clipping.durationSeconds, seconds > 0 {
                            Text(Self.durationText(seconds))
                        }
                        // Said plainly rather than discovered by pressing play.
                        if !item.isPresent {
                            Text("the audio file has gone").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .disabled(!item.isPresent)
    }

    /// Play from this clipping onwards, so the list behaves like every other list here.
    private func play(_ item: ClippingStore.Item) {
        let songs = playable
        guard let index = songs.firstIndex(where: { $0.id == item.asSong.id }) else { return }
        model.music.play(Array(songs[index...]), source: source)
    }

    /// Collect anything on the gateway this phone does not already have.
    ///
    /// Silent when no gateway is configured, which is the common case for someone who has not
    /// set one up: they should not be told about a feature they do not use. Failures say so
    /// only when the pull was asked for by hand, since an automatic collect that quietly
    /// achieves nothing is better than a banner on every visit.
    private func collect(announcing announce: Bool = false) async {
        guard !collecting else { return }
        let raw = model.agentConfig.gatewayURL.trimmingCharacters(in: .whitespaces)
        let token = model.agentConfig.gatewayToken.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !token.isEmpty, let url = URL(string: raw), url.host != nil else { return }

        collecting = true
        defer { collecting = false }

        let files = GatewayFiles(gatewayURL: url, token: token)
        do {
            let remote = try await files.list()
            // What this phone already holds, by digest. Matching on the content hash rather than
            // on the name means the same reading collected twice is one clipping, and two
            // different readings that happen to share a title are two.
            // What this phone already holds, plus what it has deliberately thrown away. Without
            // the second set a delete undoes itself: removing a clipping takes its digest out of
            // `known`, and the next refresh downloads it straight back. See
            // `ClippingStore.dismissedDigests`.
            let known = Set(store.items.compactMap(\.clipping.sha256))
            // Two different statements, deliberately kept apart: "not on this device" and
            // "gone everywhere". Collection skips the union of both.
            let dismissed = store.dismissedDigests.union(store.ledger.removedDigests)
            let wanted = remote.filter { file in
                guard let digest = file.sha256 else { return false }
                return !known.contains(digest) && !dismissed.contains(digest)
            }
            guard !wanted.isEmpty else {
                if announce { status = "Nothing new" ; await clearStatus() }
                return
            }

            var collected = 0
            for file in wanted {
                let staged = FileManager.default.temporaryDirectory
                    .appendingPathComponent("clip-\(file.id).\(Self.extensionFor(file))")
                do {
                    // `download` verifies the digest and deletes the file on a mismatch, so a
                    // truncated transfer cannot become a silently short reading.
                    try await files.download(id: file.id, expecting: file.sha256, to: staged)
                    try store.adopt(staged, title: Self.title(for: file),
                                    sourceName: file.origin, sha256: file.sha256)
                    collected += 1
                } catch {
                    try? FileManager.default.removeItem(at: staged)
                    clippingsLog.error("could not collect \(file.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if collected > 0 {
                status = "Collected \(Counted.phrase(collected, "clipping"))"
                await clearStatus()
            } else if announce {
                status = "Nothing arrived"
                await clearStatus()
            }
        } catch {
            if announce {
                status = (error as? LocalizedError)?.errorDescription ?? "Could not reach the gateway"
                await clearStatus()
            }
            clippingsLog.error("clipping collection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove the shared copy as well as this device's.
    ///
    /// No tombstone is recorded: the point of a tombstone is to stop a file coming back, and a
    /// file that is no longer on the gateway cannot. Recording one anyway would suppress a
    /// *future* clipping that happened to hash identically, which for the same audio kept again
    /// deliberately is exactly the wrong outcome.
    ///
    /// The local copy goes first. If the gateway call fails, the clipping is still gone from this
    /// phone — which is what was asked for — and the failure says the shared copy survived rather
    /// than leaving both in place and calling it an error.
    private func deleteEverywhere(_ ids: [String]) async {
        let digests = ids.compactMap { store.item(id: $0)?.clipping.sha256 }
        // `everywhere: true` writes the tombstone into the shared ledger, which is what actually
        // reaches the Mac. The gateway delete below stops a device that has never
        // seen the file collecting it afresh, but the ledger is the durable half: a gateway that
        // is unreachable still leaves a statement every device will honour later.
        for id in ids { store.remove(id: id, everywhere: true) }

        let raw = model.agentConfig.gatewayURL.trimmingCharacters(in: .whitespaces)
        let token = model.agentConfig.gatewayToken.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !token.isEmpty, let url = URL(string: raw), url.host != nil else { return }
        let files = GatewayFiles(gatewayURL: url, token: token)

        var failed = 0
        for digest in digests {
            do { try await files.delete(id: digest) } catch {
                failed += 1
                clippingsLog.error("could not delete \(digest, privacy: .public) from the gateway: \(error.localizedDescription, privacy: .public)")
            }
        }
        if failed > 0 {
            // Said plainly: without this it would look like a clean delete and then reappear on
            // another device, which is the confusing outcome this whole dialog exists to avoid.
            status = "Removed here, but \(Counted.phrase(failed, "clipping")) stayed on the gateway"
            await clearStatus()
        }
    }

    private func clearStatus() async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        status = nil
    }

    /// A readable name. The gateway carries the Mac's filename, which is already
    /// "<app> <date> <time>", so it is used as-is minus the extension rather than reformatted
    /// into something that would disagree with what the Mac shows for the same clipping.
    private static func title(for file: GatewayFiles.RemoteFile) -> String {
        let name = file.name
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[name.startIndex ..< dot])
    }

    /// Preserve the real extension so `ClippingStore` finds the file again after a relaunch,
    /// and so an older WAV clipping still plays.
    private static func extensionFor(_ file: GatewayFiles.RemoteFile) -> String {
        if let dot = file.name.lastIndex(of: "."), dot < file.name.index(before: file.name.endIndex) {
            return String(file.name[file.name.index(after: dot)...])
        }
        return file.contentType.hasSuffix("wav") ? "wav" : "m4a"
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        return minutes > 0 ? "\(minutes) min \(remainder)s" : "\(remainder)s"
    }
}
