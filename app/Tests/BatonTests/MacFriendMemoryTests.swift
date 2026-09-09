import BatonAgentKit
import BatonSubsonicModels
import Foundation
import Testing
@testable import Baton

/// D-F1 / D-F2: the memories screen the Mac's 0.18.0 What's New promised.
///
/// The card said "There is a screen for it too, so you can read what it has learned and remove
/// anything you would rather it forgot". That was true on the phone and false on the Mac,
/// where `RemoteMemoryStore` had no UI owner at all — the store was reachable only from the
/// chat router, so sentences about someone were kept, sent to a model to steer its answers, and
/// never shown to the person they were about.
///
/// **Why the view half is checked by reading the source.** Rendering `MacFriendLogView` with
/// real entries needs a `RemoteControlService`, and constructing one builds a
/// `RemoteCommandRouter`, which builds a `RemoteMemoryStore()` over the **real**
/// `~/Library/Application Support/Baton/remote-memory.json`. A unit test that reads and
/// rewrites the owner's stored memories to prove a list draws is not a trade worth making, and
/// the probe redirect that would make it safe is another workstream's. So the behaviour is
/// tested against the store directly, and the wiring — that the section exists, reads
/// `memory.entries`, shows the quote, and forgets through the store rather than around it — is
/// read out of the file. Recorded as owed: a runtime screenshot of this section.
@MainActor
@Suite("Mac friend memories")
struct MacFriendMemoryTests {
    /// …/app/Tests/BatonTests/ThisFile.swift → repo root
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// `url: nil` keeps everything in memory, so nothing touches the owner's real
    /// `remote-memory.json`; the injected defaults keep the ledger out of the real domain.
    private func store(_ defaults: UserDefaults) -> RemoteMemoryStore {
        RemoteMemoryStore(url: nil, defaults: defaults)
    }

    private func scratchDefaults() throws -> (UserDefaults, String) {
        let name = "MacFriendMemory.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    // MARK: - The list exists and shows what it promised to show

    @Test("The Mac Friend Log has a memories section, with the quote each one came from")
    func friendLogRendersMemories() throws {
        let view = try source("app/Sources/Baton/Shell/Music/MacFriendLogView.swift")
        #expect(view.contains("remote?.memory"), "the pane must read the router's live store")
        #expect(view.contains("ForEach(memory.entries)"))
        #expect(view.contains("entry.text"))
        // The quote is not decoration. It is what makes a wrong memory correctable rather than
        // merely deniable: you can see what you actually said and judge the leap.
        #expect(view.contains("entry.quote"))
        #expect(view.contains("What it remembers"))
    }

    /// Corrections and memories are different things and stay in different sections: one is the
    /// friend's inference from a thumbs-down, the other is a sentence the person said. The Mac
    /// already had "What it has learned", and the review mistook it for this.
    @Test("Memories are their own section, not merged into the corrections list")
    func memoriesAreNotTheCorrectionsList() throws {
        let view = try source("app/Sources/Baton/Shell/Music/MacFriendLogView.swift")
        #expect(view.contains("What it has learned"))
        #expect(view.contains("What it remembers"))
    }

    /// The list must not hide behind an empty conversation log. Clearing the log leaves the
    /// memories standing, and a pane that drew them only when there were exchanges would hide
    /// the sentences the app is still sending to a model.
    @Test("The memories section does not depend on there being exchanges")
    func memoriesShowWithAnEmptyLog() throws {
        let view = try source("app/Sources/Baton/Shell/Music/MacFriendLogView.swift")
        let memories = try #require(view.range(of: "if let memory, !memory.entries.isEmpty { remembered(memory) }")).lowerBound
        let logBranch = try #require(view.range(of: "if let log, !log.exchanges.isEmpty {")).lowerBound
        #expect(memories < logBranch, "the memories section sits inside the log's branch again")
    }

    @Test("Forget goes through the store, not around it")
    func forgetGoesThroughTheStore() throws {
        let view = try source("app/Sources/Baton/Shell/Music/MacFriendLogView.swift")
        #expect(view.contains("memory.forget(id: entry.id)"))
    }

    // MARK: - What forgetting actually does

    /// Forgetting one lays a tombstone as it saves. Removing the row any other way is the bug
    /// this is shaped against: an absence in the ledger is indistinguishable from "this device
    /// never heard about it", so the other device would push the memory straight back on the
    /// next sync and a working forget would read as a broken one.
    @Test("Forgetting one memory lays a tombstone rather than simply dropping it")
    func forgetLaysATombstone() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let memory = store(defaults)
        let entry = try #require(memory.remember(kind: "preference", text: "No vocals while working",
                                                 quote: "no singing while I work"))
        #expect(memory.entries.count == 1)
        memory.forget(id: entry.id)
        #expect(memory.entries.isEmpty)

        let ledger = try #require(FriendLedger.decode(defaults.data(forKey: FriendLedger.storageKey)))
        let record = try #require(ledger.memories.first { $0.text == "No vocals while working" })
        #expect(record.removed, "a forget that leaves no tombstone is undone by the next sync")
        #expect(record.removedAt != nil)
    }

    /// The Remote pane's "Delete all…" button, at the level below the button.
    @Test("Delete all lays a tombstone for every memory")
    func forgetEverythingLaysTombstones() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let memory = store(defaults)
        memory.remember(kind: "preference", text: "No vocals while working", quote: "no singing while I work")
        memory.remember(kind: "fact", text: "Their partner likes gothic playlists",
                        quote: "the gothic ones are my partner's")
        memory.forgetEverything()
        #expect(memory.entries.isEmpty)

        let ledger = try #require(FriendLedger.decode(defaults.data(forKey: FriendLedger.storageKey)))
        #expect(ledger.memories.count == 2)
        let stillLive = ledger.memories.filter { !$0.removed }.map(\.text)
        #expect(stillLive.isEmpty,
                "Delete all must tombstone, or the phone resurrects these: \(stillLive)")
    }

    // MARK: - The Settings controls the help promises

    /// `HELP.md:2295` says "Settings, Remote has a switch to turn it off and a button to delete
    /// everything." Both already existed — the review grepped `BatonSettingsView.swift`, and
    /// the Remote pane is `BatonRemotePane.swift`. What was wrong is that the delete button was
    /// disabled with the agent switch, so turning the friend off took away the only way to
    /// remove what it had already stored. A privacy control that needs the thing it protects
    /// you from is not one.
    @Test("Delete all is not gated on the friend being switched on, and asks first")
    func deleteAllIsNotGatedOnTheAgent() throws {
        let text = try source("app/Sources/Baton/Remote/BatonRemotePane.swift")
        // The switch the help promises is still there.
        #expect(text.contains("Toggle(\"Remember what you tell it\""))

        let button = try #require(text.range(of: "Button(\"Delete all…\")")).lowerBound
        let after = String(text[button...].prefix(400))
        #expect(!after.contains("isAgentEnabled"),
                "the delete button is disabled with the agent again")
        // And it asks first: the ellipsis promises a question, and it used to erase everything
        // on the first click with no way back.
        #expect(after.contains("showsForgetAllConfirm = true"))
        #expect(text.contains("Delete everything the friend remembers?"))
    }
}
