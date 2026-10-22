import Foundation
import XCTest

/// A quote or angle bracket followed by a combining mark is one Swift Character but still a raw
/// byte to the browser (D-21). Outside the page's JSON block none of the five may reach the page
/// raw before a mark; inside it, script data, no "<" at all.
func assertNoRawMarkupBeforeCombiningMark(_ html: Data, dataID: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let mark = Data("\u{301}".utf8)
    let start = try XCTUnwrap(html.range(of: Data("id=\"\(dataID)\">".utf8)), "no \(dataID) block", file: file, line: line).upperBound
    let end = try XCTUnwrap(html.range(of: Data("</script>".utf8), in: start ..< html.endIndex), file: file, line: line).lowerBound
    XCTAssertFalse(html[start ..< end].contains(UInt8(ascii: "<")), "a raw < reached the JSON block", file: file, line: line)
    let outside = html[..<start] + html[end...]
    for raw in ["\"", "<", ">", "&", "'"] {
        XCTAssertNil(outside.range(of: Data(raw.utf8) + mark), "a raw \(raw) before a combining mark reached the page", file: file, line: line)
    }
}
