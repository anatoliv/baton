import Foundation

/// Turning a complaint into a permanent test.
///
/// A rating that only tunes a prompt fixes today's answer and nothing after it: the same
/// failure can return in a month, from a model change or an unrelated edit, and nobody
/// finds out. The eval corpus in `RemoteAgentConversationEval` is the thing that would
/// notice — it already runs against a real model in the Mac gate — but its cases are
/// hand-written, so it only knows about failures somebody thought to imagine.
///
/// This turns the ones you actually hit into cases. Two rules keep the corpus honest:
///
/// - **Only wrong-track and misunderstood.** Those have an observable expectation: it
///   should have played, or it should have understood. "Too chatty" and "too slow" are
///   judgements about style and speed that no assertion can hold without inventing a
///   threshold nobody agreed to.
/// - **Verbatim, never paraphrased.** The value of a real case is that it is *what someone
///   actually typed*, phrasing and all. Tidying it up would be re-imagining the failure,
///   which is exactly what the hand-written corpus already does.
public enum FriendEvalExport {
    /// Swift source for the exportable cases, ready to paste into the corpus.
    ///
    /// Emitted as source rather than data because the corpus is source: a case that lives
    /// in a file the gate reads is a case that runs on every release, and one that lives in
    /// a JSON blob is one somebody has to remember to wire up.
    public static func swiftCases(from exchanges: [FriendExchange]) -> String {
        let usable = exchanges.filter { exchange in
            exchange.rating == .down
                && (exchange.fault == .wrongTrack || exchange.fault == .misunderstood)
                && !exchange.request.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !usable.isEmpty else { return "" }

        // Deduplicated on the request: the corpus gains nothing from the same sentence
        // three times, and a repeated annoyance would skew a pass rate that is meant to
        // describe coverage.
        var seen = Set<String>()
        let lines = usable.compactMap { exchange -> String? in
            let key = exchange.request.lowercased()
            guard seen.insert(key).inserted else { return nil }
            let escaped = exchange.request
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                // A multi-line request otherwise emits Swift that will not compile.
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            let why = exchange.note.map { note in
                " // " + note.replacingOccurrences(of: "\n", with: " ")
            } ?? " // rated \(exchange.fault?.rawValue ?? "down") on \(exchange.date.formatted(date: .abbreviated, time: .omitted))"
            // The fault cannot decide the expectation, and guessing is worse than asking.
            //
            // "Wrong track" means it understood and chose badly: it should still have
            // played. "Misunderstood" is the opposite — the archetypal case in this
            // codebase is starting music in answer to a *question*, so exporting it as
            // `.plays` would enshrine the complaint as the expected behaviour and make the
            // gate assert the bug. Those come out commented, for a human to decide.
            if exchange.fault == .wrongTrack {
                return "        Case(message: \"\(escaped)\", expect: .plays),\(why)"
            }
            return "        // TODO: .plays or .answers? — Case(message: \"\(escaped)\", expect: .plays),\(why)"
        }
        guard !lines.isEmpty else { return "" }

        return """
        // From real conversations you marked wrong. Each one is a sentence that was
        // actually typed, kept verbatim — tidying the phrasing would re-imagine the
        // failure, which the hand-written cases already do well enough.
        \(lines.joined(separator: "\n"))
        """
    }
}
