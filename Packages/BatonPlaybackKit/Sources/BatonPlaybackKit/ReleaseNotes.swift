import Foundation

/// A release's notes: what changed, in the shape both apps present it.
///
/// The Mac has shown release notes this way since the Help window shipped — one card per
/// *release*, a headline sentence, then a tight list of changes each tagged New, Improved
/// or Fixed. The phone instead drew one large card per *change*, each with its own 48pt
/// gradient tile, which turned five lines of news into a page of scrolling.
///
/// This is the shape, without any view code, so the two apps agree on what a release note
/// is even though the notes themselves differ per platform — the phone and the Mac ship on
/// their own versions and their changes are genuinely different.
public struct ReleaseNote: Identifiable, Sendable {
    public let version: String
    public let date: String
    /// One sentence on what this release is about, before the itemised list.
    public let highlight: String
    public let changes: [Change]

    public var id: String { version }

    public init(version: String, date: String, highlight: String, changes: [Change]) {
        self.version = version
        self.date = date
        self.highlight = highlight
        self.changes = changes
    }

    public struct Change: Identifiable, Sendable {
        public let id = UUID()
        public let kind: Kind
        public let text: String

        public init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Deliberately carries no colour: a package that has to import SwiftUI to describe a
    /// changelog is a package doing someone else's job. The views map these to their own
    /// palettes — and the Mac's and the phone's already agree.
    public enum Kind: String, Sendable, CaseIterable {
        case added, improved, fixed

        public var label: String {
            switch self {
            case .added: "New"
            case .improved: "Improved"
            case .fixed: "Fixed"
            }
        }
    }
}
