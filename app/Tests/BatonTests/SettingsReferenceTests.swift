import XCTest

/// HELP.md's Settings reference against the panes it describes.
///
/// The reference is the page someone opens when they cannot find a control, and it had
/// drifted badly: it called About "two small sections" and then listed three, while the
/// pane had seven. The tip jar, the theme picker, the launch-at-login switch and the
/// backup route (which HELP.md itself sends people to, from another section) were all
/// missing. Playback was missing Menu Bar and Finding music you don't have, and its
/// Advanced entry omitted the Experimental audio engine switch that the equalizer section
/// tells people to go and turn on.
///
/// None of that is the kind of thing anyone notices while writing a feature. So this reads
/// the `Section("…")` titles out of the panes and asserts each one is named in the
/// reference. It is a spelling check, not a proof that the description is any good, but it
/// makes a new section that nobody documented fail here instead of shipping.
final class SettingsReferenceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BatonTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
    }

    /// The sources that draw the Settings window.
    private let paneSources = [
        "app/Sources/Baton/Shell/Music/BatonSettingsView.swift",
        "app/Sources/Baton/Shell/Music/SupportBaton.swift",
    ]

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every `Section("…")` title in the pane sources, deduplicated.
    private func sectionTitles() throws -> [String] {
        var titles: [String] = []
        for path in paneSources {
            for line in try text(path).components(separatedBy: "\n") {
                guard let start = line.range(of: "Section(\"") else { continue }
                let rest = line[start.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { continue }
                let title = String(rest[..<end])
                if !title.isEmpty, !titles.contains(title) { titles.append(title) }
            }
        }
        return titles
    }

    /// HELP.md's "## Settings reference" section, up to the next `##`.
    private func settingsReference() throws -> String {
        let lines = try text("HELP.md").components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "## Settings reference") else {
            XCTFail("HELP.md has no Settings reference section any more")
            return ""
        }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("## ") } ?? rest.endIndex
        return rest[..<end].joined(separator: "\n")
    }

    func testThePaneSourcesWereActuallyRead() throws {
        let titles = try sectionTitles()
        XCTAssertGreaterThan(titles.count, 12, "found almost no sections, so this proves nothing")
        XCTAssertTrue(titles.contains("Support Baton"), "the tip jar section is drawn elsewhere now")
    }

    func testEverySettingsSectionIsNamedInTheReference() throws {
        let reference = try settingsReference()
        let missing = try sectionTitles().filter { !reference.contains($0) }

        XCTAssertEqual(missing, [], """
        These Settings sections exist in the app and are not named in HELP.md's Settings \
        reference: \(missing.joined(separator: ", ")). Add them there, or rename them here \
        if the section is gone.
        """)
    }

    /// The reference used to say "On iPhone, Settings is the last tab. The panes are:" and
    /// then list nine panes that only the Mac has. The phone's own sections are named now,
    /// including Queue, which the guide mentioned nowhere at all.
    func testThePhoneSettingsAreDescribedToo() throws {
        let reference = try settingsReference()

        for section in ["Server", "Equalizer", "Advanced", "Sound", "Queue", "Diagnostics", "Display"] {
            XCTAssertTrue(reference.contains("**\(section)**"),
                          "the iPhone's \(section) section is not in the Settings reference")
        }
    }

    /// The equalizer section sends people to the experimental engine. What that costs them
    /// is forty lines earlier, sold as a headline feature, and nothing used to connect the
    /// two.
    func testTheEqualizerSectionSaysWhatTheExperimentalEngineCosts() throws {
        let help = try text("HELP.md")
        guard let start = help.range(of: "## The equalizer") else {
            return XCTFail("HELP.md has no equalizer section any more")
        }
        let section = help[start.lowerBound...].prefix(4000)

        XCTAssertTrue(section.contains("gapless"), "the equalizer section does not mention gapless")
        XCTAssertTrue(section.contains("crossfade"), "the equalizer section does not mention crossfade")
        XCTAssertTrue(section.contains("#sound-quality-gapless-crossfade-loudness"),
                      "no cross-link back to the section the engine switches off")
    }
}
