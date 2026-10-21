#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import BatonShareKit
import Foundation

/// The `/b/<id>` page and its assets under `/b/_/`, with their own asset version so a book page
/// change never invalidates the song or mixtape assets. Same CSP, no-referrer and no-store as
/// `/m/` (`SharePage.pageHeaders`). Server-rendered only as far as a link preview needs: in public
/// mode the BookPreview (title, author, From, note); in private mode nothing identifying.
struct BookPage: Sendable {
    let config: ShareConfiguration
    let template: String
    let assets: [String: (type: String, body: Data)]
    let version: String
    static let types = ["book.css": "text/css; charset=utf-8", "book.mjs": "text/javascript; charset=utf-8",
                        "share-book-crypto.mjs": "text/javascript; charset=utf-8", "share-mixtape-crypto.mjs": "text/javascript; charset=utf-8",
                        "share-crypto.mjs": "text/javascript; charset=utf-8", "mixtape-manifest.mjs": "text/javascript; charset=utf-8",
                        "icon.svg": "image/svg+xml"]

    init(config: ShareConfiguration) throws {
        self.config = config
        guard let web = Bundle.module.url(forResource: "Web", withExtension: nil) else { throw ConfigurationError("Web resources missing") }
        template = try String(contentsOf: web.appendingPathComponent("book.html"), encoding: .utf8)
        var raw: [String: Data] = [:]
        var hash = SHA256()
        for name in Self.types.keys.sorted() {
            let bytes = try Data(contentsOf: web.appendingPathComponent(name))
            raw[name] = bytes; hash.update(data: bytes)
        }
        hash.update(data: Data(template.utf8))
        version = String(hash.finalize().map { String(format: "%02x", $0) }.joined().prefix(10))
        // Every module import gets the same version, so one release changes every module URL together.
        for name in Self.types.keys where name.hasSuffix(".mjs") {
            var text = String(decoding: raw[name]!, as: UTF8.self)
            for imported in Self.types.keys where imported.hasSuffix(".mjs") {
                text = text.replacingOccurrences(of: "\"./\(imported)\"", with: "\"./\(imported)?v=\(version)\"")
            }
            raw[name] = Data(text.utf8)
        }
        assets = raw.reduce(into: [:]) { $0[$1.key] = (Self.types[$1.key]!, $1.value) }
    }

    func asset(_ name: String) -> ShareResponse {
        guard let asset = assets[name] else { return .error(404, "not_found", "No such file.") }
        return .init(status: 200, contentType: asset.type, body: asset.body,
                     headers: ["Cache-Control": "public, no-cache", "X-Content-Type-Options": "nosniff"])
    }

    /// The page's JSON block (`#book-data`): only the link ID, the state and the reaction set.
    /// The page fetches everything else from `GET /v1/share/b/<id>` and authenticates it.
    struct DataBlock: Encodable { let id: String?; let state: String; let reactions: [String] }

    func render(id: String?, state: String, preview: BookPreview? = nil) -> ShareResponse {
        let from = preview?.from.isEmpty == false ? preview!.from : "Someone"
        let title: String
        let subline: String
        switch state {
        case "ready", "pending":
            title = preview.map { "\(from) sent you \($0.title)\($0.author.isEmpty ? "" : " by \($0.author)")" } ?? "Someone sent you a book"
            subline = preview?.note.isEmpty == false ? preview!.note : "Listen in your browser. No app or account needed."
        case "expired": title = "This book’s link has expired"; subline = "Ask whoever sent it for a fresh one."
        case "unsupported": title = "Book links are unavailable here"; subline = "Try opening this link when book sharing is available."
        default: title = "This link doesn’t lead anywhere"; subline = "Check that you copied all of it."
        }
        var tags = [("og:type", "website"), ("og:site_name", "Baton"), ("og:title", title), ("og:description", subline),
                    ("twitter:card", "summary"), ("twitter:title", title), ("twitter:description", subline)]
        if let id { tags.append(("og:url", config.publicBase.appendingPathComponent("b").appendingPathComponent(id).absoluteString)) }
        let og = tags.map { key, value in "<meta \(key.hasPrefix("twitter:") ? "name" : "property")=\"\(key)\" content=\"\(SharePage.escape(value))\">" }.joined(separator: "\n")
        let json = String(decoding: (try? JSONEncoder().encode(DataBlock(id: id, state: state, reactions: ShareLimits.reactions))) ?? Data("{}".utf8), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
        var html = template
        for (key, value) in ["V": version, "STATE": state, "DOC_TITLE": SharePage.escape(title), "HEADLINE": SharePage.escape(title),
                             "SUBLINE": SharePage.escape(subline), "OG_TAGS": og, "DATA": json] {
            html = html.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        let status = state == "unknown" ? 404 : state == "expired" ? 410 : state == "unsupported" ? 409 : 200
        return .init(status: status, contentType: "text/html; charset=utf-8", body: Data(html.utf8), headers: SharePage.pageHeaders)
    }
}
