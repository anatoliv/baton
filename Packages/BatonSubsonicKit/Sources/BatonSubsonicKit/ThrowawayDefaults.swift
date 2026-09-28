import Foundation

/// A `UserDefaults` suite for one test, gone once the test process is.
///
/// Every test that wanted isolated defaults minted `io.tonebox.tests.<label>.<UUID>` and
/// walked away, and so did three production fallbacks that run under XCTest
/// (`StreamingPlaybackController`, `MusicEqualizer`, `RemoteMemoryStore`), once per call.
/// By 2026-09-24 that was 20,262 plists in `~/Library/Preferences`.
///
/// Clearing the domain is not enough, which is why the tests that did clean up leaked just
/// the same. `removePersistentDomain(forName:)` empties the domain and leaves the file, and
/// `cfprefsd` writes an empty `{}` plist back about ten seconds *after* the process has
/// exited, whatever order the process cleared keys, synchronized and deleted in (measured
/// 2026-09-25; five orderings tried, every one left a stub). A delete made after that rewrite
/// sticks. So cleanup happens in three places:
///
/// - at exit, each suite this process made is emptied and its file deleted, which removes
///   everything with data in it;
/// - also at exit, on macOS, a detached cleaner waits ``lateCleanupDelay`` and deletes the same
///   files again, which removes the stub `cfprefsd` writes after the process is gone; and
/// - the first time a process asks for a suite, every file in this namespace past its stale
///   age is removed, which catches anything a killed process never got to clean up.
///
/// The sweep only touches ``namespace`` plus a UUID, so it cannot remove a fixed-name suite,
/// another project's test suite, or a suite a concurrent test run is still using.
public enum ThrowawayDefaults {
    /// Every throwaway suite's name starts with this.
    public static let namespace = "io.tonebox.tests.baton."

    /// Older than this, a throwaway suite belongs to a test process that has finished. The
    /// longest run that uses them (the UI suite) is about 40 minutes.
    public static let staleAge: TimeInterval = 2 * 60 * 60

    /// An empty `{}` plist has nothing a running test could lose, and it is exactly what
    /// `cfprefsd` leaves after a run, so it goes much sooner.
    public static let emptyStaleAge: TimeInterval = 60

    /// How long the exit cleaner waits before its second delete: well past the roughly ten
    /// seconds `cfprefsd` takes to write its stub.
    public static let lateCleanupDelay: TimeInterval = 30

    /// A fresh suite named `<namespace><label>.<UUID>`, and that name.
    public static func suite(_ label: String) -> (name: String, defaults: UserDefaults) {
        let name = name(label)
        return (name, UserDefaults(suiteName: name) ?? .standard)
    }

    /// A fresh, registered suite *name*, for a test that opens the suite itself, often more
    /// than once to stand in for a relaunch. Cleanup works by name, so opening it any number
    /// of times, or clearing it in a teardown, changes nothing.
    public static func name(_ label: String) -> String {
        let name = "\(namespace)\(label).\(UUID().uuidString)"
        registry.register(name)
        return name
    }

    /// ``suite(_:)`` for a caller that only needs the defaults.
    public static func make(_ label: String) -> UserDefaults {
        suite(label).defaults
    }

    /// Empty and delete every suite this process made. Registered with `atexit`.
    public static func removeAll() {
        let names = registry.drain()
        var paths: [String] = []
        for name in names {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            let url = plistURL(name, in: preferencesDirectory)
            try? FileManager.default.removeItem(at: url)
            paths.append(url.path)
        }
        removeLater(paths, after: lateCleanupDelay)
    }

    /// Delete `paths` again after `delay`, from a process that outlives this one. Only
    /// throwaway plists are passed, and `rm -f` on a path already gone is a no-op.
    static func removeLater(_ paths: [String], after delay: TimeInterval) {
        #if os(macOS)
        let owned = paths.filter { isThrowawayPlist(URL(fileURLWithPath: $0).lastPathComponent) }
        guard !owned.isEmpty else { return }
        let script = "trap '' HUP INT TERM; sleep \(Int(delay.rounded(.up))); rm -f -- \"$@\""
        // Batched so one very busy run never meets the argument-size limit.
        for start in stride(from: 0, to: owned.count, by: 500) {
            let batch = Array(owned[start..<min(start + 500, owned.count)])
            let cleaner = Process()
            cleaner.executableURL = URL(fileURLWithPath: "/bin/sh")
            cleaner.arguments = ["-c", script, "throwaway-defaults-cleaner"] + batch
            cleaner.standardInput = FileHandle.nullDevice
            cleaner.standardOutput = FileHandle.nullDevice
            cleaner.standardError = FileHandle.nullDevice
            try? cleaner.run()
        }
        #endif
    }

    /// Remove every throwaway plist in `directory` last modified before `now - age`, and
    /// return how many went.
    @discardableResult
    public static func sweepStale(in directory: URL, olderThan age: TimeInterval,
                                  now: Date = Date()) -> Int {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for file in names where isThrowawayPlist(file) {
            let url = directory.appendingPathComponent(file)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date else { continue }
            let threshold = isEmptyPlist(url) ? min(age, emptyStaleAge) : age
            guard now.timeIntervalSince(modified) > threshold else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// True for a plist holding an empty dictionary, which is what `cfprefsd` writes back.
    static func isEmptyPlist(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count <= 256,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return false }
        return (plist as? [String: Any])?.isEmpty == true
    }

    /// `<namespace><label>.<UUID>.plist`, and nothing else.
    static func isThrowawayPlist(_ file: String) -> Bool {
        guard file.hasPrefix(namespace), file.hasSuffix(".plist") else { return false }
        let stem = file.dropLast(".plist".count)
        guard stem.count > namespace.count + 37 else { return false }
        return UUID(uuidString: String(stem.suffix(36))) != nil && stem.dropLast(36).hasSuffix(".")
    }

    static var preferencesDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    static func plistURL(_ name: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(name).plist")
    }

    private static let registry = Registry()

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        private var started = false

        func register(_ name: String) {
            lock.lock()
            let first = !started
            started = true
            names.append(name)
            lock.unlock()
            guard first else { return }
            atexit { ThrowawayDefaults.removeAll() }
            ThrowawayDefaults.sweepStale(in: ThrowawayDefaults.preferencesDirectory,
                                         olderThan: ThrowawayDefaults.staleAge)
        }

        func drain() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            let taken = names
            names.removeAll()
            return taken
        }
    }
}
