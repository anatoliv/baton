import Foundation
import OSLog

/// In-app diagnostics: a shareable export of Baton's own recent log lines, for "podcasts won't
/// load" / "updates don't work" reports where there is otherwise no evidence path.
///
/// Privacy: the export is redacted with the same rules as crash reports (`CrashReporting.redact`),
/// so a user can share a log without leaking their server address, LAN IPs, `*.local` hosts, home
/// paths, or Subsonic auth params.
enum Diagnostics {
    /// One formatted log entry, decoupled from `OSLogEntryLog` so the formatting is unit-testable.
    struct LogLine: Equatable {
        let date: Date
        let level: String
        let category: String
        let message: String
    }

    static let subsystem = "io.tonebox.baton"

    /// Render log lines to a redacted, human-readable text block. Pure — the redactor is injected so
    /// the formatting + scrubbing is testable without a live `OSLogStore`.
    static func format(_ lines: [LogLine], redactor: (String) -> String = CrashReporting.redact) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var out = "Baton diagnostics — \(lines.count) log line(s), subsystem \(subsystem)\n\n"
        out += lines.map { line in
            "\(iso.string(from: line.date)) [\(line.level)] \(line.category): \(redactor(line.message))"
        }.joined(separator: "\n")
        return out
    }

    /// A short severity label for an `OSLogEntryLog.Level`.
    static func levelLabel(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "-"
        @unknown default: return "-"
        }
    }

    /// Query the unified log for Baton's own entries in the last `minutes`, formatted + redacted.
    /// Returns a fallback message if the store can't be opened (sandbox/entitlement). The query
    /// itself is a thin wrapper around the testable `format`.
    static func recentLogText(minutes: Int = 60, now: Date = Date()) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(date: now.addingTimeInterval(-Double(minutes) * 60))
            let entries = try store.getEntries(at: start)
            let lines: [LogLine] = entries.compactMap { entry in
                guard let log = entry as? OSLogEntryLog, log.subsystem == subsystem else { return nil }
                return LogLine(date: log.date, level: levelLabel(log.level), category: log.category, message: log.composedMessage)
            }
            return format(lines)
        } catch {
            return "Couldn't read the log store: \(error.localizedDescription)"
        }
    }

    /// Write exported log text to a temp file named for sharing, returning its URL.
    static func writeExport(_ text: String, now: Date = Date(), directory: URL? = nil) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let dir = directory ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("baton-diagnostics-\(stamp).txt")
        do {
            try text.data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
