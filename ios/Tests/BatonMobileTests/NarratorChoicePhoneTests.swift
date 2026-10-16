import XCTest
import BatonDocuments
@testable import BatonMobile

/// The phone's narrator choice: from the home server's `GET /v1/voices`, ordered and
/// defaulted as the Mac's import sheet does without a model suggestion (the shared `VoiceCaster`
/// and `VoiceCatalogue`), and today's single configured default when the gateway is older.
@MainActor
final class NarratorChoicePhoneTests: XCTestCase {
    /// A home server answering `/v1/voices` with `voices`, or with `status` alone.
    private func gateway(status: Int = 200, voices: [String] = []) -> GatewayBookClient {
        let list = GatewayVoiceList(voices: voices.map { spec in
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            return GatewayVoiceList.Voice(engine: parts[0], id: parts[1], language: VoiceCatalogue.declaredLanguage(spec))
        }, sources: ["kokoro": "server"])
        let body = status == 200 ? try! JSONEncoder().encode(list) : Data(#"{"error":"not found"}"#.utf8)
        return GatewayBookClient(baseURL: URL(string: "http://home.test:8788")!, token: "t") { request in
            XCTAssertEqual(request.url?.path, "/v1/voices")
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    private func book(region: String? = nil, language: String? = "en") -> ImportedDocument {
        ImportedDocument(sourceSHA256: "n-\(region ?? "none")", sourceKind: .html, title: "Colour", language: language,
                         languageRegion: region,
                         chapters: [DocumentChapter(index: 0, title: "One", paragraphs: ["The colour was grey."])])
    }

    /// Heart, Emma, a dialogue voice and the two avoided ones, as a small Kokoro might list them.
    private let offered = ["kokoro:af_aoede", "kokoro:af_bella", "kokoro:af_heart", "kokoro:bf_emma", "kokoro:bm_lewis"]

    func testAnAmericanOrUnspecifiedEnglishBookOffersHeartFirstAndNeverTheAvoidedVoices() async throws {
        for document in [book(), book(region: "us"), book(language: nil)] {
            let found = await MobileDocuments.narratorChoice(for: document, client: gateway(voices: offered))
            let choice = try XCTUnwrap(found)
            let options = [choice.primary] + choice.alternates
            XCTAssertEqual(options, ["kokoro:af_heart", "kokoro:bf_emma", "kokoro:af_bella"], "\(document.languageRegion ?? "none")")
            XCTAssertFalse(options.contains("kokoro:af_aoede") || options.contains("kokoro:bm_lewis"))
        }
    }

    func testABookDeclaringBritishEnglishOffersEmmaFirst() async throws {
        let found = await MobileDocuments.narratorChoice(for: book(region: "gb"), client: gateway(voices: offered))
        let choice = try XCTUnwrap(found)
        XCTAssertEqual([choice.primary] + choice.alternates, ["kokoro:bf_emma", "kokoro:af_heart", "kokoro:af_bella"])
    }

    /// The whole of Kokoro's English list, as the gateway lists it when Kokoro answers: the
    /// Mac's fallback order, narration voices after the default (Heart, then Adam, then Emma).
    func testTheFullKokoroListGivesTheMacsOrder() async throws {
        let found = await MobileDocuments.narratorChoice(for: book(), client: gateway(voices: VoiceCatalogue.kokoroEnglishVoices))
        let choice = try XCTUnwrap(found)
        XCTAssertEqual([choice.primary] + choice.alternates, ["kokoro:af_heart", "kokoro:am_adam", "kokoro:bf_emma"])
    }

    /// An older gateway (404), one that does not answer, an empty list, or no home server: no
    /// choice, so the screen shows the configured default exactly as before.
    func testWithoutAVoiceListTheScreenKeepsTodaysDefault() async {
        let notFound = await MobileDocuments.narratorChoice(for: book(), client: gateway(status: 404))
        XCTAssertNil(notFound)
        let refused = await MobileDocuments.narratorChoice(for: book(), client: gateway(status: 503))
        XCTAssertNil(refused)
        let empty = await MobileDocuments.narratorChoice(for: book(), client: gateway(voices: []))
        XCTAssertNil(empty)
        let none = await MobileDocuments.narratorChoice(for: book(), client: nil)
        XCTAssertNil(none)
    }

    /// The chosen narrator is the book's narrator, whichever of the three it is.
    func testTheChosenNarratorIsWhatTheBookCarries() async throws {
        let document = book()
        let found = await MobileDocuments.narratorChoice(for: document, available: offered)
        let choice = try XCTUnwrap(found)
        for option in [choice.primary] + choice.alternates {
            let prepared = DocumentSpeech.prepare(document, voices: .forBook(narrator: option, suggestion: choice))
            XCTAssertEqual(prepared.voices.narrator, option)
            XCTAssertNil(prepared.voices.speed, "a fallback choice carries no suggested speed")
        }
    }
}
