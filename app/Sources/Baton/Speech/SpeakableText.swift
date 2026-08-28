import Foundation

/// Turns text scraped off the screen into text worth listening to.
///
/// Reading a screen aloud is mostly a text problem wearing an audio costume: raw terminal
/// scrollback read verbatim — prompts, escape codes, forty-character hashes, every brace
/// pronounced — is unlistenable, and a copied web page is half navigation. So the pipeline is
///
///     redact → normalize → chunk
///
/// and every stage is a pure function over strings, with no AppKit, no engine and no I/O. That
/// is deliberate: this is the one part of the read-aloud feature a test suite can genuinely
/// prove, so it carries as much of the judgement as possible.
///
/// **Redaction runs first, unconditionally, on every tier.** A terminal has credentials on
/// screen, and a reading is spoken aloud in a room and shown in the HUD. Readings are never
/// persisted (see `specs/read-aloud.md`), so there is no redaction-at-rest problem — but there
/// is very much a redaction-out-loud one.
enum SpeakableText {

    // MARK: - Source profiles

    /// Where the text came from, which decides how much cleaning it needs. Chosen from the
    /// frontmost application's bundle id by `ScreenTextReader`.
    enum SourceProfile: String, CaseIterable, Sendable {
        case terminal
        case browser
        case generic
    }

    // MARK: - The whole pipeline

    /// Redact, normalize, then split into speakable chunks. The order is not negotiable:
    /// redaction happens before anything else can copy, reflow or split a secret into a shape
    /// the patterns no longer match.
    static func prepare(_ raw: String, profile: SourceProfile) -> [String] {
        chunks(normalize(redact(raw), profile: profile))
    }

    // MARK: - Redaction

    /// Credential shapes, replaced with a spoken placeholder rather than their value.
    ///
    /// Deliberately narrow: these are *known credential shapes*, not "anything that looks
    /// random". A forty-character git SHA is not a secret, and turning it into "a redacted
    /// token" would be both wrong and alarming — the normalizer gives it a spoken shorthand
    /// instead. Over-redaction is a real failure mode here, not a safe default.
    private static let secretPatterns: [(pattern: String, replacement: String)] = [
        // A private key block, from header to footer, however long.
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "a redacted private key"),
        // OpenAI and friends.
        (#"\bsk-[A-Za-z0-9_-]{16,}"#, "a redacted token"),
        // GitHub personal access / OAuth / server / user-to-server / refresh tokens.
        (#"\bgh[pousr]_[A-Za-z0-9]{16,}"#, "a redacted token"),
        // Sentry auth tokens, the estate's own (see the global notes on the release token).
        (#"\bsntry[su]_[A-Za-z0-9_\-\.=]{16,}"#, "a redacted token"),
        // Slack.
        (#"\bxox[baprs]-[A-Za-z0-9-]{10,}"#, "a redacted token"),
        // AWS access key ids.
        (#"\bAKIA[0-9A-Z]{16}\b"#, "a redacted key"),
        // Google API keys. Length is deliberately a floor rather than the documented exact 35:
        // the `AIza` prefix is distinctive enough that a near-miss length is far likelier to be
        // a real key than a false positive, and under-redacting is the dangerous direction.
        (#"\bAIza[0-9A-Za-z_-]{30,}"#, "a redacted key"),
        // JSON Web Tokens.
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, "a redacted token"),
        // Anything handed over as a bearer credential.
        (#"(?i)\bbearer\s+[A-Za-z0-9._\-+/=]{12,}"#, "bearer, a redacted token"),
        // key=value and key: value assignments whose *name* says it is a secret.
        (#"(?i)\b(api[-_]?key|secret|password|passwd|token|auth)\b\s*[:=]\s*\S+"#, "$1, a redacted value"),
    ]

    /// Replace every known credential shape with a spoken placeholder. Idempotent: the
    /// placeholders themselves match nothing here.
    static func redact(_ text: String) -> String {
        var out = text
        for (pattern, replacement) in secretPatterns {
            out = out.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression]
            )
        }
        return out
    }

    // MARK: - Normalization

    /// Clean text for the ear, by profile. Shared work first, then whatever the source needs.
    static func normalize(_ text: String, profile: SourceProfile) -> String {
        var out = text

        // Escape sequences first: they are invisible on screen and catastrophic when spoken,
        // and stripping them everywhere costs nothing (a browser selection has none).
        out = stripControlSequences(out)

        switch profile {
        case .terminal: out = terminalPass(out)
        case .browser: out = browserPass(out)
        case .generic: break
        }

        out = announceCodeBlocks(out)
        out = shortenOpaqueTokens(out)
        out = shortenURLs(out)
        out = expandAbbreviations(out)
        out = collapseWhitespace(out)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ANSI/CSI colour and cursor codes, OSC title/hyperlink strings, and stray control bytes.
    private static func stripControlSequences(_ text: String) -> String {
        var out = text
        // OSC: ESC ] ... BEL, or ESC ] ... ESC \
        out = out.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",
                                       with: "", options: [.regularExpression])
        // CSI: ESC [ params final-byte
        out = out.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",
                                       with: "", options: [.regularExpression])
        // Any other two-byte escape.
        out = out.replacingOccurrences(of: "\u{1B}.", with: "", options: [.regularExpression])
        // Carriage returns used for in-place progress redraws, and remaining control bytes
        // other than newline and tab.
        out = out.replacingOccurrences(of: "\r", with: "\n")
        out = out.replacingOccurrences(of: "[\u{00}-\u{08}\u{0B}\u{0C}\u{0E}-\u{1F}\u{7F}]",
                                       with: "", options: [.regularExpression])
        return out
    }

    /// A shell prompt line, in the shapes these terminals actually produce:
    /// `user@host dir % cmd`, `dir $ cmd`, `➜ dir cmd`, `#`-rooted, and so on.
    private static let promptLine = #"^\s*(?:[\w.@\-]+@[\w.\-]+\s+)?[^\n%$#>]{0,80}?\s*[%$#>➜]\s"#

    /// Terminal cleaning: keep the output, lose the furniture.
    ///
    /// When a selection spans several commands, only the last command's output is spoken.
    /// Selecting a screenful in order to hear the thing that just failed is the common case,
    /// and reading the previous six commands first defeats it.
    private static func terminalPass(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let promptIndices = lines.indices.filter { isPromptLine(lines[$0]) }

        var kept = lines
        if let last = promptIndices.last, promptIndices.count > 1, last < lines.count - 1 {
            // Speak the last command and everything after it.
            kept = Array(lines[last...])
        }

        // Drop the prompt decorations themselves but keep the command that was typed, which is
        // the useful half of a prompt line.
        return kept.map { line -> String in
            guard isPromptLine(line) else { return line }
            let command = line.replacingOccurrences(of: promptLine, with: "", options: [.regularExpression])
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "" : "Command: \(trimmed)."
        }
        .joined(separator: "\n")
    }

    private static func isPromptLine(_ line: String) -> Bool {
        line.range(of: promptLine, options: [.regularExpression]) != nil
    }

    /// Lines a copied web page brings along that nobody wants read to them. Matched whole and
    /// case-insensitively, so an article *about* cookie banners keeps its sentences.
    private static let webBoilerplate: Set<String> = [
        "skip to content", "skip to main content", "menu", "search", "sign in", "log in",
        "subscribe", "share", "advertisement", "accept all cookies", "accept cookies",
        "manage cookies", "cookie settings", "newsletter", "follow us", "related articles",
        "read more", "back to top", "privacy policy", "terms of service", "all rights reserved",
    ]

    private static func browserPass(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { line in
                let key = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !webBoilerplate.contains(key)
            }
            .joined(separator: "\n")
    }

    /// A fenced code block becomes a sentence about itself. Reading braces and semicolons aloud
    /// is the single fastest way to make someone turn the feature off.
    private static func announceCodeBlocks(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "```([A-Za-z0-9+#-]*)\\n([\\s\\S]*?)```") else {
            return text
        }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let language = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            let lines = body.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .count
            let named = language.isEmpty ? "Code block" : "\(language) code block"
            result += "\(named), \(lines) \(lines == 1 ? "line" : "lines")."
            cursor = m.range.location + m.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Hashes, UUIDs and long opaque runs get a spoken shorthand rather than being spelled out.
    /// These are *not* redactions — a commit SHA is not a secret, it is merely unspeakable.
    private static func shortenOpaqueTokens(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(
            of: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
            with: "a UUID", options: [.regularExpression])
        // Hex runs of 7+ (a short git SHA is 7) become "an N-character hash".
        if let re = try? NSRegularExpression(pattern: #"\b[0-9a-f]{7,}\b"#) {
            let ns = out as NSString
            var result = ""
            var cursor = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                result += "a \(spelled(m.range.length))-character hash"
                cursor = m.range.location + m.range.length
            }
            result += ns.substring(from: cursor)
            out = result
        }
        // Long unbroken opaque runs (base64-ish) that survived everything above.
        out = out.replacingOccurrences(of: #"\b[A-Za-z0-9+/=_-]{40,}\b"#,
                                       with: "a long identifier", options: [.regularExpression])
        return out
    }

    private static func spelled(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// A spoken URL is noise. Keep the host, drop the path — "a link to example.com" carries
    /// everything a listener can act on.
    private static func shortenURLs(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"https?://([^\s/]+)(/\S*)?"#) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let host = ns.substring(with: m.range(at: 1))
            result += "a link to \(host.replacingOccurrences(of: "www.", with: ""))"
            cursor = m.range.location + m.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Abbreviations whose periods both read badly and break sentence splitting. Expanded
    /// before chunking for exactly that second reason.
    private static let abbreviations: [(String, String)] = [
        (#"\be\.g\.\s*"#, "for example, "),
        (#"\bi\.e\.\s*"#, "that is, "),
        (#"\betc\.(?=\s|$)"#, "et cetera"),
        (#"\bvs\.\s*"#, "versus "),
        (#"\bapprox\.\s*"#, "approximately "),
        (#"\bcf\.\s*"#, "compare "),
        (#"\bw/\s"#, "with "),
        (#"\s&\s"#, " and "),
    ]

    private static func expandAbbreviations(_ text: String) -> String {
        var out = text
        for (pattern, replacement) in abbreviations {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression])
        }
        return out
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[ \t]+", with: " ", options: [.regularExpression])
            .replacingOccurrences(of: " *\n *", with: "\n", options: [.regularExpression])
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: [.regularExpression])
    }

    // MARK: - Chunking

    /// Never emit a one-word utterance: below this, a chunk is merged into the next one.
    static let minChunkCharacters = 40
    /// Never emit a chunk that takes most of a minute to speak. Roughly 25 seconds of audio.
    static let maxChunkCharacters = 320

    /// Split into sentence-sized units for speaking.
    ///
    /// Sentence granularity is not cosmetic. Kokoro returns a WAV with no word timings, so the
    /// read-along highlight on the server path can only be as fine as one utterance — which
    /// makes "one sentence per utterance" the difference between a usable highlight and none.
    /// It also lets playback start after the first sentence renders rather than the whole
    /// document.
    static func chunks(_ text: String,
                       minCharacters: Int = minChunkCharacters,
                       maxCharacters: Int = maxChunkCharacters) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var sentences: [String] = []
        trimmed.enumerateSubstrings(in: trimmed.startIndex..., options: [.bySentences, .localized]) { s, _, _, _ in
            if let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if sentences.isEmpty { sentences = [trimmed] }

        // Long sentences split at clause boundaries before they are hard-split, so a break
        // lands somewhere a speaker would have paused anyway.
        let sized = sentences.flatMap { split($0, max: maxCharacters) }

        // Short fragments merge forward, so a stray "OK." never becomes its own utterance.
        var merged: [String] = []
        for piece in sized {
            if let last = merged.last,
               last.count < minCharacters,
               last.count + piece.count + 1 <= maxCharacters {
                merged[merged.count - 1] = last + " " + piece
            } else {
                merged.append(piece)
            }
        }
        return merged
    }

    private static func split(_ sentence: String, max: Int) -> [String] {
        guard sentence.count > max else { return [sentence] }
        var pieces: [String] = []
        var current = ""
        // Clause boundaries first; whitespace is the fallback so a pathological run of
        // punctuation-free text still terminates.
        for clause in sentence.components(separatedBy: [";", ":", ","]) {
            let candidate = current.isEmpty ? clause : current + "," + clause
            if candidate.count > max, !current.isEmpty {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
                current = clause
            } else {
                current = candidate
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            pieces.append(current.trimmingCharacters(in: .whitespaces))
        }
        return pieces.flatMap { piece -> [String] in
            guard piece.count > max else { return [piece] }
            return hardSplit(piece, max: max)
        }
    }

    private static func hardSplit(_ text: String, max: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.count + word.count + 1 > max, !current.isEmpty {
                pieces.append(current)
                current = String(word)
            } else {
                current = current.isEmpty ? String(word) : current + " " + word
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
