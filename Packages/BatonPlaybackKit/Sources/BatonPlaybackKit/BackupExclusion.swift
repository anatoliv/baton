import Foundation
import OSLog

private let backupLog = Logger(subsystem: "io.tonebox.baton", category: "BackupExclusion")

/// Keeps audio Baton can get again out of the iPhone's backups (DOC-24,
/// `specs/document-clippings.md`, *Storage → Backups*).
///
/// A narrated book is hundreds of megabytes of chapter audio, and a music download is a copy of
/// something on the server. Both can always be downloaded or rendered again, so backing them up
/// spends the owner's iCloud quota on bytes that are never the only copy. What *cannot* be got
/// again stays in the backup: a clipping's sidecar (its title, source and text), the download
/// manifest and metadata, ledgers, and any `.corrupt-…` copy kept aside as evidence. A restore
/// that lost a sidecar would leave audio nobody can identify, which is the failure this must
/// never cause, so the rule is decided by **file type**, never by directory.
///
/// **Per file, not an excluded subdirectory.** Clippings keep audio and sidecar side by side, and
/// downloads may live in a folder the user picked. Moving audio into a separate excluded
/// directory would change both layouts and every path already on disk; setting the flag on each
/// audio file changes nothing anyone reads.
///
/// **iOS only.** On the Mac, Time Machine backing up a music library and the clippings in it is
/// what people expect, and a Mac has the disk for it, so nothing is excluded there. The
/// functions below work on every platform so the rule can be tested on the Mac; the stores only
/// call them where `appliesOnThisPlatform` is true.
///
/// The flag is a resource value on the file itself, so it must be set after the file exists, at
/// its final path. A rename within a volume keeps it (`BackupExclusionTests` pins that); a file
/// written fresh does not have it, which is why the stores mark audio once more at launch and
/// not only when they write it.
public enum BackupExclusion {

    /// Whether re-creatable audio is kept out of backups on this platform. See the type's note.
    public static let appliesOnThisPlatform: Bool = {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }()

    /// Extensions that are audio. Everything else in a store's directory stays in the backup.
    ///
    /// Every container the download sniffer can name, plus what a renderer or exporter writes and
    /// what an audiobook arrives as.
    public static let audioExtensions: Set<String> = Set(AudioContainer.allCases.map(\.rawValue))
        .union(["aac", "aif", "caf", "m4b", "oga", "opus"])

    /// Whether `url` names an audio file, by its extension. A sidecar `<id>.json`, a quarantined
    /// `<id>.json.corrupt-<timestamp>` and a hidden manifest are not.
    public static func isAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// The audio files directly inside `directory`: what a store whose directory is entirely its
    /// own should exclude. Not recursive, because a store's audio sits at its top level and a
    /// subdirectory is somebody else's layout.
    public static func audioFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name -> URL? in
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard isAudio(url),
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return nil }
            return url
        }
    }

    /// Whether the file is currently excluded. Read from a fresh URL, because a `URL` caches the
    /// resource values it has already fetched and would answer with the old one.
    public static func isExcluded(_ url: URL) -> Bool {
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }

    /// Exclude one file. Returns true when the flag was newly set, false when it was already set
    /// or could not be (a missing file, a volume that refuses it); a failure is logged, never
    /// thrown, because the file is still perfectly playable and the cost is only backup space.
    @discardableResult
    public static func exclude(_ url: URL) -> Bool {
        guard !isExcluded(url) else { return false }
        var target = URL(fileURLWithPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
            return true
        } catch {
            backupLog.error("could not exclude \(url.lastPathComponent, privacy: .public) from backup: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Exclude each file that is not already. Returns how many were newly marked, which is what
    /// the launch sweep logs: zero on every launch after the first is the healthy answer.
    @discardableResult
    public static func exclude(_ urls: [URL]) -> Int {
        urls.reduce(0) { $0 + (exclude($1) ? 1 : 0) }
    }
}
