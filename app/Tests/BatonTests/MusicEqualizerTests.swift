import Foundation
import Testing
@testable import Baton

@Suite("Equalizer biquads")
struct MusicEqualizerTests {
    @Test("0 dB gain is the identity filter (no coloration)")
    func flatIsIdentity() {
        let b = Biquad.peaking(frequency: 1000, sampleRate: 44100, q: 1, gainDB: 0)
        #expect(b.b0 == 1 && b.b1 == 0 && b.b2 == 0 && b.a1 == 0 && b.a2 == 0)
    }

    @Test("A boost raises the passband gain; a cut lowers it")
    func boostAndCut() {
        // DC-ish response magnitude ~ (b0+b1+b2)/(1+a1+a2); boost > 1, cut < 1 near center.
        let boost = Biquad.peaking(frequency: 1000, sampleRate: 44100, q: 1, gainDB: 6)
        let cut = Biquad.peaking(frequency: 1000, sampleRate: 44100, q: 1, gainDB: -6)
        // Coefficients differ from identity for a non-zero gain.
        #expect(boost.b0 != 1)
        #expect(cut.b0 != 1)
        #expect(boost.b0 > cut.b0)
    }
}
