import Foundation

/// Known credential shapes, replaced with a spoken placeholder before anything else touches the
/// text: before it is shaped, rendered, stored, or sent to a model.
///
/// This is the one list. Read-aloud on the Mac (`SpeakableText.redact`), document import on the
/// iPhone and the gateway all call it, so a key in a PDF is treated exactly as a key on screen.
/// The placeholders are spoken aloud, so changing one changes what a listener hears;
/// `SecretRedactorTests` pins them word for word.
///
/// Deliberately narrow: these are known credential shapes, not "anything that looks random". A
/// git SHA is not a secret, and over-redaction is a real failure mode, not a safe default.
///
/// Foundation only, and ICU regex syntax only, because the gateway builds this on Linux.
public enum SecretRedactor {
    public static let patterns: [(pattern: String, replacement: String)] = [
        // A private key block, from header to footer, however long.
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "a redacted private key"),
        // OpenAI and friends.
        (#"\bsk-[A-Za-z0-9_-]{16,}"#, "a redacted token"),
        // GitHub personal access / OAuth / server / user-to-server / refresh tokens.
        (#"\bgh[pousr]_[A-Za-z0-9]{16,}"#, "a redacted token"),
        // Sentry auth tokens.
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

    /// Replace every known credential shape. Idempotent: the placeholders match nothing.
    public static func redact(_ text: String) -> String {
        var out = text
        for (pattern, replacement) in patterns {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression])
        }
        return out
    }

    /// The same list with one marker for every shape, for text that is read rather than heard:
    /// a crash report says `<redacted-secret>` where read-aloud says "a redacted token". A
    /// `name = value` assignment keeps its name, so `password=<redacted-secret>` still says which
    /// field it was. Idempotent as long as the marker matches no pattern.
    public static func redact(_ text: String, placeholder: String) -> String {
        var out = text
        for (pattern, replacement) in patterns {
            let marker = replacement.contains("$1") ? "$1=" + placeholder : placeholder
            out = out.replacingOccurrences(of: pattern, with: marker, options: [.regularExpression])
        }
        return out
    }

    /// The whole document, every paragraph and title.
    public static func redact(_ document: ImportedDocument) -> ImportedDocument {
        var copy = document
        copy.title = redact(document.title)
        copy.author = document.author.map(redact)
        copy.frontMatter = document.frontMatter.map(redact)
        copy.chapters = document.chapters.map { chapter in
            var c = chapter
            c.title = redact(chapter.title)
            c.paragraphs = chapter.paragraphs.map(redact)
            return c
        }
        return copy
    }
}
