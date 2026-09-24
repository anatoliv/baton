import XCTest
@testable import BatonMCPProtocol

/// TBX-7306: the port scan is decided without a socket. These pin the order, the sibling skip
/// and the notice text; the app target's MCPPortSurfacingTests cover the real bind.
final class MCPPortScanTests: XCTestCase {
    func testCandidatesStartAtThePreferredPortAndWalkUpward() {
        XCTAssertEqual(BatonMCPPortScan.candidates(preferred: 9000, count: 4, skipping: []),
                       [9000, 9001, 9002, 9003])
    }

    func testCandidatesSkipSiblingDefaultsWithoutShrinkingTheRange() {
        let ports = BatonMCPPortScan.candidates(preferred: 8787)
        XCTAssertEqual(ports.count, BatonMCPConstants.portScanRange)
        XCTAssertEqual(Array(ports.prefix(4)), [8787, 8788, 8790, 8791], "8789 is Seedbed's default")
        XCTAssertFalse(ports.contains(8789))
    }

    func testAPreferredPortThatIsASiblingDefaultIsStillTriedFirst() {
        let ports = BatonMCPPortScan.candidates(preferred: 8789, count: 3)
        XCTAssertEqual(ports, [8789, 8790, 8791], "the user asked for it; honour it")
    }

    func testEveryDefaultSiblingIsInTheSkipSet() {
        XCTAssertEqual(BatonMCPPortScan.siblingDefaultPorts, [8765, 8784, 8789])
        XCTAssertFalse(BatonMCPPortScan.siblingDefaultPorts.contains(BatonMCPConstants.defaultPort),
                       "Baton's own default is not a sibling")
    }

    func testCandidatesStopAtTheTopOfThePortRange() {
        XCTAssertEqual(BatonMCPPortScan.candidates(preferred: 65534, count: 16, skipping: []), [65534, 65535])
        XCTAssertEqual(BatonMCPPortScan.candidates(preferred: 8787, count: 0), [])
    }

    func testFirstFreeSkipsTheSeedbedDefaultWhen8787And8788AreTaken() async {
        var probed: [UInt16] = []
        let bound = await BatonMCPPortScan.firstFree(preferred: 8787) { port in
            probed.append(port)
            return port != 8787 && port != 8788
        }
        XCTAssertEqual(bound, 8790)
        XCTAssertEqual(probed, [8787, 8788, 8790], "8789 must never even be probed")
    }

    func testFirstFreeReturnsThePreferredPortWhenItIsFree() async {
        let bound = await BatonMCPPortScan.firstFree(preferred: 8787) { _ in true }
        XCTAssertEqual(bound, 8787)
    }

    func testFirstFreeIsNilWhenEveryCandidateIsTaken() async {
        var probes = 0
        let bound = await BatonMCPPortScan.firstFree(preferred: 8787) { _ in probes += 1; return false }
        XCTAssertNil(bound)
        XCTAssertEqual(probes, BatonMCPConstants.portScanRange)
    }

    func testLastCandidateNamesTheEndOfTheScan() {
        XCTAssertEqual(BatonMCPPortScan.lastCandidate(preferred: 8787), 8803, "16 candidates, one skipped")
    }

    func testPreferredPortReadsAStoredValueAndFallsBackOnJunk() {
        let defaults = UserDefaults(suiteName: "MCPPortScanTests-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        XCTAssertEqual(BatonMCPPortScan.preferredPort(from: defaults), BatonMCPConstants.defaultPort)
        defaults.set(9123, forKey: BatonMCPConstants.preferredPortDefaultsKey)
        XCTAssertEqual(BatonMCPPortScan.preferredPort(from: defaults), 9123)
        defaults.set(80, forKey: BatonMCPConstants.preferredPortDefaultsKey)
        XCTAssertEqual(BatonMCPPortScan.preferredPort(from: defaults), BatonMCPConstants.defaultPort, "privileged port is not usable")
        defaults.set(70000, forKey: BatonMCPConstants.preferredPortDefaultsKey)
        XCTAssertEqual(BatonMCPPortScan.preferredPort(from: defaults), BatonMCPConstants.defaultPort)
        defaults.set("8790", forKey: BatonMCPConstants.preferredPortDefaultsKey)
        XCTAssertEqual(BatonMCPPortScan.preferredPort(from: defaults), BatonMCPConstants.defaultPort, "a string is not a port")
    }

    func testNoticeMessageNamesBothPortsWithoutDashes() {
        let notice = BatonMCPPortNotice(preferred: 8787, bound: 8788)
        XCTAssertEqual(notice.message, "Port 8787 was in use. Baton is on 8788. Update your MCP client, or use mcp.json.")
        XCTAssertFalse(notice.message.contains("\u{2014}") || notice.message.contains("\u{2013}"))
    }
}
