#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import BatonShareKit
import Foundation

/// The player page at `/s/<id>` and its static assets (spec §4.2).
///
/// The page is server-rendered only as far as a link preview needs: the Open Graph tags, the
/// headline, and the state, so a crawler that runs no script still gets a real card and a person
/// with scripts off still gets a real message. Everything else — decrypting, the waveform, the
/// reactions — is `player.mjs`, reading the same state from a JSON block in the page.
public struct SharePage: Sendable {
    let config: ShareConfiguration
    let template: String
    /// Asset name → (content type, bytes). Loaded once; the service never reads the disk for them.
    let assets: [String: (type: String, body: Data)]
    /// A content hash of every asset together, appended as `?v=` to select a fresh
    /// URL on deploy. The query is not an archive: old queries still serve current bytes.
    public let version: String

    static let assetTypes = [
        "player.css": "text/css; charset=utf-8",
        "player.mjs": "text/javascript; charset=utf-8",
        "share-crypto.mjs": "text/javascript; charset=utf-8",
        "icon.svg": "image/svg+xml",
    ]

    public init(config: ShareConfiguration) throws {
        self.config = config
        guard let web = Bundle.module.url(forResource: "Web", withExtension: nil) else {
            throw ConfigurationError("the Web resources are missing from the bundle")
        }
        template = try String(contentsOf: web.appendingPathComponent("player.html"), encoding: .utf8)
        var raw: [String: Data] = [:]
        for name in Self.assetTypes.keys.sorted() {
            raw[name] = try Data(contentsOf: web.appendingPathComponent(name))
        }
        var hasher = SHA256()
        for name in raw.keys.sorted() { hasher.update(data: raw[name]!) }
        hasher.update(data: Data(template.utf8))
        version = String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(10))

        // The player imports the crypto module by a relative path. Give that import the same
        // version so a release changes both module URLs. Mutable paths still revalidate;
        // a query marker does not make old bytes available for an immutable lifetime.
        let player = String(decoding: raw["player.mjs"]!, as: UTF8.self)
            .replacingOccurrences(of: "\"./share-crypto.mjs\"", with: "\"./share-crypto.mjs?v=\(version)\"")
        raw["player.mjs"] = Data(player.utf8)
        assets = raw.reduce(into: [:]) { $0[$1.key] = (Self.assetTypes[$1.key]!, $1.value) }
    }

    public func shareURL(id: String) -> String {
        config.publicBase.appendingPathComponent("s").appendingPathComponent(id).absoluteString
    }

    func asset(named name: String) -> ShareResponse {
        guard let asset = assets[name] else { return .error(404, "not_found", "No such file.") }
        return ShareResponse(status: 200, contentType: asset.type, body: asset.body, headers: [
            // Assets live at mutable paths, including URLs carrying a previous query hash.
            "Cache-Control": "public, no-cache",
            "X-Content-Type-Options": "nosniff",
        ])
    }

    // MARK: - Rendering

    /// Security headers for every page. The CSP is the whole of the page's network surface:
    /// its own scripts and styles, its own API, artwork and audio from blobs it made itself.
    static let pageHeaders = [
        "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; "
            + "img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self'; manifest-src 'none'; "
            + "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        "Referrer-Policy": "no-referrer",
        "X-Robots-Tag": "noindex, nofollow, noarchive",
        "X-Content-Type-Options": "nosniff",
        "Cache-Control": "no-store",
        "Permissions-Policy": "camera=(), microphone=(), geolocation=(), interest-cohort=()",
    ]

    struct PageData: Encodable {
        let state: String
        let id: String?
        let share: PublicShare?
        let links: [String: String]
        let reactions: [String]
    }

    func render(_ state: ShareService.PublicState) -> ShareResponse {
        let status: Int
        let stateName: String
        var id: String?
        var share: PublicShare?
        switch state {
        case .unknown:
            status = 404
            stateName = "unknown"
        case let .pending(record):
            status = 200
            stateName = "pending"
            id = record.id
            share = Self.publicShare(record)
        case let .ready(record):
            status = 200
            stateName = "ready"
            id = record.id
            share = Self.publicShare(record)
        case let .ended(record, code):
            status = 410
            stateName = code
            id = record.id
            // A capped share still shows what it was; an expired or revoked one has no content left.
            share = code == "play_cap" ? Self.publicShare(record) : nil
        }

        let preview = share?.preview
        let from = preview?.from.isEmpty == false ? preview!.from : "Someone"
        let headline: String
        let subline: String
        switch stateName {
        case "ready", "pending":
            if let preview {
                headline = "\(from) sent you \(preview.title)\(preview.artist.isEmpty ? "" : " by \(preview.artist)")"
                subline = preview.note.isEmpty ? "Tap to listen. No app or account needed." : preview.note
            } else {
                headline = "Someone sent you a song"
                subline = "Tap to listen. No app or account needed."
            }
        case "play_cap":
            headline = "This link has been played a lot"
            subline = "Ask \(from == "Someone" ? "whoever sent it" : from) for a fresh one."
        case "expired", "revoked":
            headline = "This song’s link has expired"
            subline = "Ask whoever sent it to send it again."
        default:
            headline = "This link doesn’t lead anywhere"
            subline = "Check that you copied all of it."
        }

        var og: [(String, String)] = [
            ("og:type", "music.song"), ("og:site_name", "Baton"), ("og:title", headline),
            ("og:description", subline), ("twitter:title", headline), ("twitter:description", subline),
        ]
        if let id {
            og.append(("og:url", shareURL(id: id)))
            let api = config.publicBase.absoluteString.trimmingSuffix("/") + "/v1/share/p/\(id)"
            if share?.hasCard == true {
                og += [("og:image", "\(api)/card"), ("og:image:width", "1200"), ("og:image:height", "630"),
                       ("twitter:card", "summary_large_image"), ("twitter:image", "\(api)/card")]
            } else if share?.hasArt == true, share?.encryptedMeta == nil {
                og += [("og:image", "\(api)/art"), ("twitter:card", "summary"), ("twitter:image", "\(api)/art")]
            } else {
                og.append(("twitter:card", "summary"))
            }
        }
        let ogTags = og.map { key, value in
            let attribute = key.hasPrefix("twitter:") ? "name" : "property"
            return "<meta \(attribute)=\"\(key)\" content=\"\(Self.escape(value))\">"
        }.joined(separator: "\n    ")

        let data = PageData(state: stateName, id: id, share: share, links: [
            "appStore": config.appStoreURL, "macDownload": config.macDownloadURL, "about": config.aboutURL,
        ], reactions: ShareLimits.reactions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = ((try? encoder.encode(data)).map { String(decoding: $0, as: UTF8.self) } ?? "{}")
            // Inside <script>, "</" ends the block whatever JSON thinks; escape every "<".
            .replacingOccurrences(of: "<", with: "\\u003c")

        let html = template
            .replacingOccurrences(of: "{{V}}", with: version)
            .replacingOccurrences(of: "{{STATE}}", with: stateName)
            .replacingOccurrences(of: "{{DOC_TITLE}}", with: Self.escape(headline))
            .replacingOccurrences(of: "{{OG_TAGS}}", with: ogTags)
            .replacingOccurrences(of: "{{HEADLINE}}", with: Self.escape(headline))
            .replacingOccurrences(of: "{{SUBLINE}}", with: Self.escape(subline))
            .replacingOccurrences(of: "{{ABOUT_URL}}", with: Self.escape(config.aboutURL))
            .replacingOccurrences(of: "{{DATA}}", with: json)
        return ShareResponse(status: status, contentType: "text/html; charset=utf-8", body: Data(html.utf8),
                             headers: Self.pageHeaders)
    }

    static func publicShare(_ record: ShareRecord) -> PublicShare {
        PublicShare(status: record.status, preview: record.preview, encryptedMeta: record.encryptedMeta,
                    audioBytes: record.audioBytes, hasArt: record.artType != nil, hasCard: record.cardType != nil,
                    expiresAt: ShareDate.string(Date(timeIntervalSince1970: TimeInterval(record.expiresAt))))
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

/// Separate page and asset version: adding mixtapes does not invalidate single-song assets.
struct MixtapePage: Sendable {
    let config: ShareConfiguration
    let template: String
    let assets: [String: (type: String, body: Data)]
    let version: String
    static let types = ["mixtape.css": "text/css; charset=utf-8", "mixtape.mjs": "text/javascript; charset=utf-8",
                        "mixtape-manifest.mjs": "text/javascript; charset=utf-8", "share-mixtape-crypto.mjs": "text/javascript; charset=utf-8",
                        "share-crypto.mjs": "text/javascript; charset=utf-8", "icon.svg": "image/svg+xml"]
    init(config: ShareConfiguration) throws {
        self.config = config
        guard let web = Bundle.module.url(forResource: "Web", withExtension: nil) else { throw ConfigurationError("Web resources missing") }
        template = try String(contentsOf: web.appendingPathComponent("mixtape.html"), encoding: .utf8)
        var raw: [String: Data] = [:]
        var hash = SHA256()
        for name in Self.types.keys.sorted() {
            let bytes = try Data(contentsOf: web.appendingPathComponent(name))
            raw[name] = bytes; hash.update(data: bytes)
        }
        hash.update(data: Data(template.utf8))
        version = String(hash.finalize().map { String(format: "%02x", $0) }.joined().prefix(10))
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
    struct DataBlock: Encodable { let id: String?; let state: String; let reactions: [String] }
    func render(id: String?, state: String, preview: MixtapePreview? = nil) -> ShareResponse {
        let from = preview?.from.isEmpty == false ? preview!.from : "Someone"
        let title: String
        let subline: String
        switch state {
        case "ready", "pending":
            title = preview.map { "\(from) sent you \($0.title)" } ?? "Someone sent you a mixtape"
            subline = preview?.note.isEmpty == false ? preview!.note : "Listen in order. No app or account needed."
        case "expired": title = "This mixtape’s link has expired"; subline = "Ask whoever sent it for a fresh one."
        case "unsupported": title = "Mixtapes are unavailable here"; subline = "Try opening this link when mixtape sharing is available."
        default: title = "This link doesn’t lead anywhere"; subline = "Check that you copied all of it."
        }
        var tags = [("og:type", "website"), ("og:site_name", "Baton"), ("og:title", title), ("og:description", subline),
                    ("twitter:card", "summary"), ("twitter:title", title), ("twitter:description", subline)]
        if let id { tags.append(("og:url", config.publicBase.appendingPathComponent("m").appendingPathComponent(id).absoluteString)) }
        let og = tags.map { key, value in "<meta \(key.hasPrefix("twitter:") ? "name" : "property")=\"\(key)\" content=\"\(SharePage.escape(value))\">" }.joined(separator: "\n")
        let json = String(decoding: (try? JSONEncoder().encode(DataBlock(id: id, state: state, reactions: ShareLimits.reactions))) ?? Foundation.Data("{}".utf8), as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
        var html = template
        for (key, value) in ["V": version, "STATE": state, "DOC_TITLE": SharePage.escape(title), "HEADLINE": SharePage.escape(title),
                             "SUBLINE": SharePage.escape(subline), "OG_TAGS": og, "DATA": json] {
            html = html.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        let status = state == "unknown" ? 404 : state == "expired" ? 410 : state == "unsupported" ? 409 : 200
        return .init(status: status, contentType: "text/html; charset=utf-8", body: Foundation.Data(html.utf8), headers: SharePage.pageHeaders)
    }
}
