import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BatonDocuments

/// The HTML parser and the article reader: furniture out, the article in, headings to
/// chapters, and the URL path's identity and errors.
final class HTMLParserTests: XCTestCase {
    func testForgivingParse() {
        let doc = HTMLParser.parse("""
        <!DOCTYPE html><html><head><title>A &amp; B</title>
        <script>if (a < b) { document.write("</div><p>not text</p>") }</script></head>
        <body><!-- a comment with <p>markup</p> -->
        <p class=intro>One<p>Two &mdash; three&#8212;four &#x2014; five&nbsp;six &unknown; AT&T
        <ul><li>first<li>second</ul>
        <div/><br/><img src="x.png" alt="pic">
        <![CDATA[raw <text>]]>
        </span></body></html>
        """)
        XCTAssertEqual(doc.first(named: "title")?.textContent, "A & B")
        let ps = doc.descendants(named: ["p"]).map(\.textContent)
        let dash = String(Typography.emDash)
        XCTAssertEqual(ps, ["One", "Two \(dash) three\(dash)four \(dash) five six &unknown; AT&T"])
        XCTAssertEqual(doc.descendants(named: ["li"]).map(\.textContent), ["first", "second"])
        XCTAssertEqual(doc.first(named: "p")?.attribute("class"), "intro")
        XCTAssertFalse(doc.first(named: "body")!.textContent.contains("not text"))
        XCTAssertFalse(doc.first(named: "body")!.textContent.contains("markup"))
        XCTAssertTrue(doc.first(named: "body")!.textContent.contains("raw <text>"))
    }

    func testWindows1252NumericReferencesAreWhatThePageMeant() {
        XCTAssertEqual(HTMLParser.decodeEntities("&#147;Hi&#148; &#151; &#133;"),
                       "\u{201C}Hi\u{201D} \(Typography.emDash) \u{2026}")
    }

    func testEncodingFollowsTheDeclaration() {
        var bytes = Data("<html><head><meta charset=\"windows-1252\"></head><body><p>caf".utf8)
        bytes.append(0xE9)
        bytes.append(contentsOf: Array("</p></body></html>".utf8))
        let text = HTMLParser.decode(bytes)
        XCTAssertTrue(text.contains("caf\u{00E9}"), text)
        // Undeclared and not UTF-8: Windows-1252, as a browser assumes.
        var undeclared = Data("<p>na".utf8)
        undeclared.append(0xEF)
        undeclared.append(contentsOf: Array("ve</p>".utf8))
        XCTAssertTrue(HTMLParser.decode(undeclared).contains("na\u{00EF}ve"))
        // The header wins over the page.
        XCTAssertTrue(HTMLParser.decode(bytes, contentType: "text/html; charset=ISO-8859-1").contains("caf\u{00E9}"))
    }
}

final class HTMLImporterTests: XCTestCase {
    /// A news page with everything a reader mode has to see past.
    static let newsPage = """
    <!doctype html>
    <html lang="en-GB"><head>
      <title>The Quiet Machines | The Daily Example</title>
      <meta property="og:title" content="The Quiet Machines">
      <meta name="author" content="Ada Example">
      <script src="tracker.js"></script>
    </head><body>
      <div class="cookie-banner">We use cookies. <button>Accept</button></div>
      <header class="site-header"><a href="/">The Daily Example</a><nav><a href="/news">News</a><a href="/sport">Sport</a></nav></header>
      <div class="layout">
        <aside class="sidebar"><p>Most read: something else entirely, with commas, many, many, of them, to tempt the scorer.</p></aside>
        <article>
          <header><h1>The Quiet Machines</h1><p class="byline">By Ada Example</p></header>
          <div class="share-buttons"><a href="#">Share on Example</a></div>
          <p>The machines in the basement had been running for a hundred years, and nobody remembered who had switched them on.<sup><a href="#fn1">1</a></sup></p>
          <p>Engineers came and went, each certain that the next generation would understand what the last had built, and each was wrong.</p>
          <figure><img src="m.jpg"><figcaption>A machine, photographed in 1931.</figcaption></figure>
          <table><tr><th>Year</th><th>Machines</th></tr><tr><td>1931</td><td>12</td></tr></table>
          <h2>What they did</h2>
          <p>Nobody could say for certain. Some thought they kept the lights on; others, that they kept the lights off.</p>
          <p>See also <a href="/a">this</a>, <a href="/b">that</a> and <a href="/c">the other thing we wrote last week</a>.</p>
          <h2>Why it matters</h2>
          <p>Because the day they stop, somebody will have to decide whether to start them again.</p>
          <pre><code>print("not read aloud")</code></pre>
        </article>
        <section class="comments"><h3>Comments</h3><p>First! This is a comment that should never be read aloud, however long it is.</p></section>
      </div>
      <div class="related-stories"><a href="/x">Another story</a></div>
      <footer><p>Copyright The Daily Example.</p></footer>
    </body></html>
    """

    func testANewsPageReadsAsItsArticle() throws {
        let out = HTMLImporter.read(Self.newsPage, fallbackTitle: "page")
        XCTAssertEqual(out.result.title, "The Quiet Machines")
        XCTAssertEqual(out.result.author, "Ada Example")
        XCTAssertEqual(out.language, "en")
        XCTAssertEqual(out.result.stats.paragraphRule, .markup)
        let text = out.result.chapters.flatMap(\.paragraphs).joined(separator: "\n")
        XCTAssertTrue(text.hasPrefix("The machines in the basement had been running for a hundred years, and nobody remembered who had switched them on."), text)
        for furniture in ["cookies", "Accept", "Sport", "Most read", "Share on", "First!", "Another story", "Copyright",
                          "photographed", "1931", "not read aloud", "By Ada"] {
            XCTAssertFalse(text.contains(furniture), "read \(furniture): \(text)")
        }
        XCTAssertFalse(text.contains("on.1"), "the footnote marker is not read")
        // Two h2s are the chapters; the opening paragraphs come before them and are long
        // enough to be their own section rather than a title page.
        XCTAssertEqual(out.result.chapters.map(\.title), ["", "What they did", "Why it matters"])
        XCTAssertEqual(out.result.chapters[1].paragraphs.count, 1, "a 'see also' line that is mostly links is navigation")
        XCTAssertFalse(text.contains("See also"))
        XCTAssertEqual(out.warnings, [ImportWarning(.contentSkipped, detail: "1 table, 1 code block, 1 figure")])
    }

    func testDivSoupIsScoredToItsText() {
        let paragraph = "This sentence, with its commas, clauses, and asides, is the kind of thing an article is made of, and there is plenty of it."
        let html = """
        <html><head><title>Notes - My Blog</title></head><body>
        <div id="top"><div class="menu"><a href="/">Home</a> <a href="/about">About</a></div></div>
        <div id="wrap"><div id="left"><p>Short promo text here, sign up.</p></div>
          <div id="post">\((0..<6).map { "<p>\(paragraph) \($0)</p>" }.joined())</div>
          <div id="post-more">\((0..<3).map { "<p>\(paragraph) more \($0)</p>" }.joined())</div>
        </div>
        <div id="foot"><p>Powered by a blog engine, version three, with plugins, themes, and widgets.</p></div>
        </body></html>
        """
        let out = HTMLImporter.read(html, fallbackTitle: "x")
        let paragraphs = out.result.chapters.flatMap(\.paragraphs)
        XCTAssertEqual(paragraphs.count, 9, "\(paragraphs)")
        XCTAssertTrue(paragraphs.last!.hasSuffix("more 2"))
        XCTAssertFalse(paragraphs.contains { $0.contains("Powered") || $0.contains("promo") })
        XCTAssertEqual(out.result.title, "Notes", "the site name is not the title")
        XCTAssertFalse(out.result.foundHeadings)
    }

    /// The shape of Project Gutenberg's HTML edition (structure only; the text is made up).
    static let gutenbergPage = """
    <!DOCTYPE html><html lang="en"><head>
    <title>The Project Gutenberg eBook of A Made-Up Book, by Jane Q. Writer</title>
    <meta name="dc.creator" content="Writer, Jane Q. (Jane Quentin), 1870-1940">
    </head><body>
    <section class="pg-boilerplate pgheader" id="pg-header"><h2>The Project Gutenberg eBook of A Made-Up Book</h2>
    <p>This ebook is for the use of anyone anywhere in the United States and most other parts of the world.</p></section>
    <h1>A MADE-UP BOOK</h1>
    <h2 class="no-break">by Jane Q. Writer</h2>
    <p class="center">First published 1909</p>
    <h2>CONTENTS</h2>
    <table><tr><td><a href="#c1">I. The Air-Ship</a></td><td>3</td></tr><tr><td><a href="#c2">II. The Mending Apparatus</a></td><td>20</td></tr></table>
    <div class="chapter"><h2><a id="c1"></a>CHAPTER I</h2><h3>THE AIR-SHIP</h3>
    <p>Imagine, if you can, a small room, hexagonal in shape, like the cell of a bee.</p>
    <p>An armchair is in the centre, by its side a reading-desk; that is all the furniture.</p>
    <div class="poem"><div class="stanza"><span>The air is still,</span><br><span>the room is warm,</span><br><span>the lights are low,</span><br><span>and nothing stirs.</span></div></div>
    </div>
    <div class="chapter"><h2><a id="c2"></a>CHAPTER II. The Mending Apparatus</h2>
    <p>By a vestibule, by a lift, by a tubular railway, by a platform, by a sliding door.</p>
    </div>
    <section class="pg-boilerplate pgheader" id="pg-footer"><p>*** END OF THE PROJECT GUTENBERG EBOOK A MADE-UP BOOK ***</p>
    <p>Updated editions will replace the previous one.</p></section>
    </body></html>
    """

    func testAGutenbergBookComesOutAsChapters() throws {
        let out = HTMLImporter.read(Self.gutenbergPage, fallbackTitle: "pg")
        XCTAssertEqual(out.result.title, "A Made-Up Book")
        XCTAssertEqual(out.result.author, "Jane Q. Writer")
        XCTAssertTrue(out.result.foundHeadings)
        let chapters = out.result.chapters
        XCTAssertEqual(chapters.map(\.title), ["THE AIR-SHIP", "The Mending Apparatus"])
        XCTAssertEqual(chapters.map(\.label), ["Chapter I", "Chapter II"])
        XCTAssertEqual(chapters[0].spokenHeading, "Chapter I. THE AIR-SHIP")
        XCTAssertEqual(chapters[0].paragraphs.count, 6, "two paragraphs and four verse lines: \(chapters[0].paragraphs)")
        XCTAssertEqual(chapters[0].paragraphs[2], "The air is still,")
        XCTAssertEqual(out.result.frontMatter, ["First published 1909"])
        let all = chapters.flatMap(\.paragraphs).joined()
        XCTAssertFalse(all.contains("ebook") || all.contains("Updated editions") || all.contains("Mending Apparatus 20"))
        XCTAssertEqual(out.warnings, [], "the contents table is links, so it is navigation, not a skipped table")
    }

    /// What Gutenberg's illustrated editions do (measured on Pride and Prejudice, #1342): a
    /// picture and its caption inside the chapter heading, the first letter as a picture, the
    /// printed page numbers inline.
    func testIllustratedEditionsReadAsText() {
        let html = """
        <html><head><title>Pride and prejudice | Project Gutenberg</title><meta name="dc.title" content="A Made-Up Book"></head><body>
        <h1><img alt="" src="front.png"><br><i>A MADE-UP.<br>BOOK</i></h1>
        <p>by</p><p>Jane Q. Writer,</p><p>with a Preface by</p><p>Some Critic</p>
        <h2><a id="PREFACE"></a><span class="pagenum"><a id="page_ix">{ix}</a></span><img alt="PREFACE." src="i_010.jpg"></h2>
        <p>A preface, long enough to be read, about the book that follows it.</p>
        <h2><a id="c1"></a><img alt="" src="i_030.jpg"><br><br>Chapter I.</h2>
        <p><span class="letra"><img alt="I" src="i.png"></span>T is a truth universally acknowledged, not too<span class="pagenum"><a id="page_23">{23}</a></span> clever.</p>
        <h2><a id="c2"></a><img alt="" src="i_035.jpg"><span class="caption">I hope Mr. Bingley will like it.</span><br><br>CHAPTER II.</h2>
        <p><span class="letra"><img alt="M" src="m.png"></span>R. BENNET was among the earliest.</p>
        </body></html>
        """
        let out = HTMLImporter.read(html, fallbackTitle: "x")
        XCTAssertEqual(out.result.title, "A Made-Up Book")
        XCTAssertEqual(out.result.chapters.map(\.title), ["PREFACE.", "Chapter I", "Chapter II"])
        XCTAssertEqual(out.result.chapters[1].paragraphs, ["IT is a truth universally acknowledged, not too clever."])
        XCTAssertEqual(out.result.chapters[2].paragraphs, ["MR. BENNET was among the earliest."])
        XCTAssertEqual(out.result.frontMatter, ["A MADE-UP. BOOK", "by", "Jane Q. Writer,", "with a Preface by", "Some Critic"],
                       "a title page is shown, not read")
    }

    /// An encyclopedia article: notes about the page, and the apparatus at the end, are not read.
    func testAnEncyclopediaArticle() {
        let body = "A science fiction short story, first published in 1909, about a world that lives underground and relies on a machine."
        let html = """
        <html><head><title>The Machine Stops - Wikipedia</title><meta property="og:title" content="The Machine Stops - Wikipedia"></head>
        <body><main><h1>The Machine Stops</h1>
        <div id="siteSub" class="noprint">From Wikipedia, the free encyclopedia</div>
        <div class="hatnote navigation-not-searchable">For the album, see The Machine Stops (album).</div>
        <p>\(body)</p><h2>Plot<span class="mw-editsection">[edit]</span></h2><p>\(body)</p>
        <h2>Themes</h2><p>\(body)</p>
        <h2>References</h2><ol class="references"><li>Forster, E. M. (1947). Collected Short Stories, a reference long enough to count.</li></ol>
        <h2>External links</h2><ul><li>Wikiquote has quotations related to The Machine Stops, at some length.</li></ul>
        </main></body></html>
        """
        let out = HTMLImporter.read(html, fallbackTitle: "x")
        XCTAssertEqual(out.result.title, "The Machine Stops")
        XCTAssertEqual(out.result.chapters.map(\.title), ["", "Plot", "Themes"])
        let text = out.result.chapters.flatMap(\.paragraphs).joined(separator: " ")
        XCTAssertFalse(text.contains("Wikipedia") || text.contains("album") || text.contains("[edit]") || text.contains("1947"), text)
        XCTAssertEqual(out.warnings.first?.detail, "the References, External links sections")
    }

    /// An essay set the old way (paulgraham.com): one element, paragraphs as `<br><br>`, the
    /// title as a picture, headings with a "¶" link.
    func testParagraphsSetWithLineBreaks() {
        let html = """
        <html><head><title>How to Do Great Work</title></head><body><table><tr><td><img src="nav.gif">
        <font size="2" face="verdana">July 2023<br><br>If you collected lists of techniques for doing great work, what would the intersection look like?<br><br>
        I decided to find out by making it.<br><br>Partly my goal was to create a guide that could be used by someone working in any field.</font>
        </td></tr></table></body></html>
        """
        XCTAssertEqual(HTMLImporter.read(html, fallbackTitle: "x").result.chapters.flatMap(\.paragraphs), [
            "July 2023",
            "If you collected lists of techniques for doing great work, what would the intersection look like?",
            "I decided to find out by making it.",
            "Partly my goal was to create a guide that could be used by someone working in any field.",
        ])
        let docs = """
        <html><body><div role="main"><h1>Intro<a class="headerlink" href="#intro">\u{00B6}</a></h1><p>Some text that is long enough to count.</p>
        <h2>Numbers<a class="headerlink" href="#n">\u{00B6}</a></h2><p>About numbers, at some length.</p><h3>I.</h3><p>A section.</p>
        <h2>Text<a class="headerlink" href="#t">\u{00B6}</a></h2><p>About text, at some length.</p></div></body></html>
        """
        let out = HTMLImporter.read(docs, fallbackTitle: "x")
        XCTAssertEqual(out.result.title, "Intro")
        XCTAssertEqual(out.result.chapters.map(\.title), ["", "Numbers", "Text"], "the opening sentence is read, untitled")
        XCTAssertEqual(out.result.chapters[1].paragraphs, ["About numbers, at some length.", "A section."])
    }

    func testOlderGutenbergFilesAreCutAtTheirMarkers() {
        let html = """
        <html><body><p>The Project Gutenberg EBook of Something. This eBook is for the use of anyone.</p>
        <p>*** START OF THIS PROJECT GUTENBERG EBOOK SOMETHING ***</p>
        <p>The real first sentence of the book, which is what should be read first.</p>
        <p>*** END OF THIS PROJECT GUTENBERG EBOOK SOMETHING ***</p><p>Licence text.</p></body></html>
        """
        let paragraphs = HTMLImporter.read(html, fallbackTitle: "x").result.chapters.flatMap(\.paragraphs)
        XCTAssertEqual(paragraphs, ["The real first sentence of the book, which is what should be read first."])
    }

    func testHeadingsSplitIntoLabelAndTitle() {
        XCTAssertEqual(HTMLImporter.splitHeading("CHAPTER IV. The Storm").label, "Chapter IV")
        XCTAssertEqual(HTMLImporter.splitHeading("CHAPTER IV. The Storm").title, "The Storm")
        XCTAssertEqual(HTMLImporter.splitHeading("Part Two").label, "Part Two")
        XCTAssertNil(HTMLImporter.splitHeading("Part Two").title)
        XCTAssertEqual(HTMLImporter.splitHeading("I\nTHE AIR-SHIP").label, "I")
        XCTAssertEqual(HTMLImporter.splitHeading("I\nTHE AIR-SHIP").title, "THE AIR-SHIP")
        XCTAssertEqual(HTMLImporter.splitHeading("XII.").label, "XII")
        XCTAssertEqual(HTMLImporter.splitHeading("3. Eggs").label, "3")
        XCTAssertNil(HTMLImporter.splitHeading("I Am Legend").label, "a title that starts with I is not numbered")
        XCTAssertNil(HTMLImporter.splitHeading("Introduction").label)
    }

    func testPersonNames() {
        XCTAssertEqual(HTMLImporter.personName("Forster, E. M. (Edward Morgan), 1879-1970"), "E. M. Forster")
        XCTAssertEqual(HTMLImporter.personName("Austen, Jane"), "Jane Austen")
        XCTAssertEqual(HTMLImporter.personName("By Ada Example"), "Ada Example")
        XCTAssertEqual(HTMLImporter.personName("Ada Example"), "Ada Example")
    }

    func testAScriptOnlyPageIsRefusedWithTheReason() throws {
        let html = "<html><head><script src=a.js></script><script src=b.js></script></head><body><div id=root></div><script>render()</script></body></html>"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).html")
        try Data(html.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try DocumentImporter.importFile(at: url)) { error in
            guard case DocumentImporter.Failure.unreadable(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("JavaScript"), why)
        }
    }

    func testAnHTMLFileImportsThroughTheFrontDoor() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-machines.html")
        try Data(Self.newsPage.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try DocumentImporter.importFile(at: url)
        XCTAssertEqual(doc.sourceKind, .html)
        XCTAssertEqual(doc.title, "The Quiet Machines")
        XCTAssertEqual(doc.language, "en")
        XCTAssertEqual(doc.chapters[0].title, "The Quiet Machines", "the untitled opening takes the document's title")
        XCTAssertEqual(doc.sourceSHA256, SHA256Digest.hex(of: Data(Self.newsPage.utf8)))
        // And it prepares for speech like any other document.
        let book = DocumentSpeech.prepare(doc, voices: VoicePlan(narrator: "kokoro:bf_emma"))
        XCTAssertEqual(book.chapters.count, 3)
    }
}

final class URLImportTests: XCTestCase {
    private func fetch(status: Int = 200, type: String? = "text/html; charset=utf-8", finalURL: String? = nil,
                       body: @escaping @Sendable () -> Data) -> DocumentImporter.Fetch {
        { request in
            let url = finalURL.flatMap(URL.init(string:)) ?? request.url!
            var headers: [String: String] = [:]
            if let type { headers["Content-Type"] = type }
            return (body(), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
    }

    func testTheSameArticleWithDifferentAdsIsTheSameBook() async throws {
        let url = URL(string: "https://example.org/2026/quiet-machines")!
        let page = HTMLImporterTests.newsPage
        let first = try await DocumentImporter.importURL(url, fetch: fetch { Data(page.replacingOccurrences(of: "tracker.js", with: "t.js?v=1").utf8) })
        let second = try await DocumentImporter.importURL(url, fetch: fetch { Data(page.replacingOccurrences(of: "tracker.js", with: "t.js?v=2").utf8) })
        XCTAssertEqual(first.sourceKind, .url)
        XCTAssertEqual(first.fileName, url.absoluteString)
        XCTAssertEqual(first.title, "The Quiet Machines")
        XCTAssertEqual(first.sourceSHA256, second.sourceSHA256)
        XCTAssertEqual(first.sourceSHA256.count, 64)
    }

    func testTheAddressAfterRedirectsIsKept() async throws {
        let doc = try await DocumentImporter.importURL(URL(string: "https://short.example/x")!,
                                                       fetch: fetch(finalURL: "https://example.org/long/path") { Data(HTMLImporterTests.newsPage.utf8) })
        XCTAssertEqual(doc.fileName, "https://example.org/long/path")
    }

    func testPlainTextAddresses() async throws {
        let doc = try await DocumentImporter.importURL(URL(string: "https://example.org/files/notes.txt")!,
                                                       fetch: fetch(type: "text/plain") { Data("A note, read aloud.\n\nA second paragraph.".utf8) })
        XCTAssertEqual(doc.chapters.flatMap(\.paragraphs), ["A note, read aloud.", "A second paragraph."])
        XCTAssertEqual(doc.title, "Notes")
    }

    func testRefusalsSayWhy() async {
        let cases: [(URL, DocumentImporter.Fetch, String)] = [
            (URL(string: "file:///etc/passwd")!, fetch { Data() }, "Only web addresses"),
            (URL(string: "https://example.org/paid")!, fetch(status: 403) { Data() }, "signing in"),
            (URL(string: "https://example.org/gone")!, fetch(status: 404) { Data() }, "error 404"),
            (URL(string: "https://example.org/song.mp3")!, fetch(type: "audio/mpeg") { Data([1, 2, 3]) }, "audio/mpeg"),
            (URL(string: "https://example.org/huge")!, fetch { Data(count: DocumentImporter.maximumPageBytes + 1) }, "larger"),
        ]
        for (url, f, expected) in cases {
            do {
                _ = try await DocumentImporter.importURL(url, fetch: f)
                XCTFail("\(url) should be refused")
            } catch DocumentImporter.Failure.unreadable(let why) {
                XCTAssertTrue(why.contains(expected), "\(url): \(why)")
            } catch {
                XCTFail("\(url): \(error)")
            }
        }
    }

    /// A real page, when `BATON_LIVE_URL` names one: prints what was read, so a person can
    /// judge the extraction (the cloud session runs it against a few real sites).
    func testARealPage() async throws {
        guard let address = ProcessInfo.processInfo.environment["BATON_LIVE_URL"], let url = URL(string: address) else {
            throw XCTSkip("set BATON_LIVE_URL to read a real page")
        }
        let doc = try await DocumentImporter.importURL(url) { try await URLSession.shared.data(for: $0) }
        print("TITLE: \(doc.title) | AUTHOR: \(doc.author ?? "-") | LANG: \(doc.language ?? "-") | WORDS: \(doc.wordCount)")
        print("WARNINGS: \(doc.warnings)")
        print("FRONT: \(doc.frontMatter)")
        for chapter in doc.chapters.prefix(60) {
            print("== [\(chapter.label ?? "")] \(chapter.title) (\(chapter.paragraphs.count) paragraphs)")
            for p in chapter.paragraphs.prefix(ProcessInfo.processInfo.environment["BATON_LIVE_URL_LINES"].flatMap(Int.init) ?? 2) {
                print("   \(p.prefix(140))")
            }
        }
        XCTAssertGreaterThan(doc.wordCount, 100)
    }
}
