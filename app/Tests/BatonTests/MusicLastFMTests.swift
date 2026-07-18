import CryptoKit
import Foundation
import Testing
@testable import Baton

@MainActor
@Suite("Last.fm signing")
struct MusicLastFMTests {
    private func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02hhx", $0) }.joined()
    }

    @Test("api_sig is md5 of sorted name+value pairs plus the secret")
    func signature() {
        // Sorted: "api_key"+"KEY", then "method"+"auth.getToken", then the secret.
        let params = ["method": "auth.getToken", "api_key": "KEY"]
        let sig = MusicLastFM.signature(params, secret: "SECRET")
        #expect(sig == md5("api_keyKEYmethodauth.getTokenSECRET"))
        #expect(sig.count == 32)
    }

    @Test("format would change the signature — so callers must add it after signing")
    func excludesFormat() {
        let a = MusicLastFM.signature(["method": "track.scrobble"], secret: "s")
        let b = MusicLastFM.signature(["method": "track.scrobble", "format": "json"], secret: "s")
        #expect(a != b)
    }
}
