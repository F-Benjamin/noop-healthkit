import XCTest
@testable import WhoopProtocol

final class BevelExportTests: XCTestCase {
    private func bytes(_ raw: Int = 1024, flags: UInt8 = 0x16) -> [UInt8] {
        [flags, 60, UInt8(raw & 255), UInt8(raw >> 8)]
    }
    private func captures() -> [BevelCapture] {
        (0..<60).map { i in
            BevelCapture(id: "p\(i)", session: "connection1", receivedAt: Double(600 + i),
                         bytes: bytes(i % 2 == 0 ? 1000 : 1048))
        }
    }
    private func plan(_ c: [BevelCapture]) -> BevelExport.Plan {
        BevelExport.plan(captures: c, deviceID: "strap-A", minute: 600, now: 665)
    }
    func testPrecisionAndOptionalFields() throws {
        let m = try XCTUnwrap(BevelExport.parse([0x1F, 0x2C, 1, 0xFF, 0xFF, 1, 4, 0, 4]))
        XCTAssertEqual(m.bpm, 300)
        XCTAssertEqual(m.rrMS, [1000.9765625, 1000])
        XCTAssertEqual(m.contact, .supportedDetected)
    }
    func testMalformedPackets() {
        for p: [UInt8] in [[], [0], [1, 60], [8, 60], [8, 60, 0], [16, 60], [16, 60, 0], [0, 60, 0], [0x80, 60]] {
            XCTAssertNil(BevelExport.parse(p), "\(p)")
        }
    }
    func testKnownSampleSDAndIdentity() throws {
        let p = plan(captures())
        let sd = try XCTUnwrap(p.samples.last)
        XCTAssertEqual(p.samples.count, 61)
        XCTAssertEqual(sd.kind, .sdnn)
        // 30 x 976.5625 and 30 x 1023.4375 ms, mean 1000, n-1 denominator.
        XCTAssertEqual(sd.value, sqrt(60 * pow(23.4375, 2) / 59), accuracy: 1e-10)
        XCTAssertEqual(sd.acceptedBeats, 60)
        XCTAssertEqual(sd.id, "bevel-v3:strap-A:sdnn:600")
        XCTAssertEqual(plan(captures() + captures()).samples, p.samples)
        XCTAssertEqual(plan(captures().reversed()).samples, p.samples)
        let other = BevelExport.plan(captures: captures(), deviceID: "strap-B", minute: 600, now: 665)
        XCTAssertNotEqual(other.samples.last?.id, sd.id)
    }
    func testNoRRNeverInventsSDNN() {
        let c = captures().map { BevelCapture(id: $0.id, session: $0.session, receivedAt: $0.receivedAt, bytes: [0, 60]) }
        XCTAssertEqual(plan(c).samples.count, 60)
        XCTAssertFalse(plan(c).samples.contains { $0.kind == .sdnn })
    }
    func testIsolatedPacketsWithoutRRAreToleratedWhenMeasuredCoverageRemainsComplete() {
        let c = captures().enumerated().map { i, packet in
            BevelCapture(id: packet.id, session: packet.session, receivedAt: packet.receivedAt,
                         bytes: i == 10 || i == 20 ? [0x06, 60] : packet.bytes)
        }
        XCTAssertTrue(plan(c).samples.contains { $0.kind == .sdnn })
    }
    func testGapsContactReconnectArtifactsAndOvercountRefuseSDNN() {
        var reconnect = captures()
        reconnect[30] = BevelCapture(id: "new", session: "connection2", receivedAt: 630, bytes: bytes())
        let offWrist = captures().map { BevelCapture(id: $0.id, session: $0.session, receivedAt: $0.receivedAt, bytes: bytes(flags: 0x14)) }
        let artifacts = captures().enumerated().map { i, p in
            BevelCapture(id: p.id, session: p.session, receivedAt: p.receivedAt, bytes: bytes(i % 4 == 0 ? 2000 : 1024))
        }
        let overcount = captures().map { BevelCapture(id: $0.id, session: $0.session, receivedAt: $0.receivedAt, bytes: bytes() + [0, 4]) }
        for c in [captures().filter { !(620...630).contains(Int($0.receivedAt)) }, reconnect, offWrist, artifacts, overcount] {
            XCTAssertFalse(plan(c).samples.contains { $0.kind == .sdnn })
        }
        XCTAssertTrue(plan(offWrist).samples.isEmpty)
    }
    func testIncompleteWindowAndEventRoundTrip() throws {
        XCTAssertTrue(BevelExport.plan(captures: captures(), deviceID: "a", minute: 600, now: 664).samples.isEmpty)
        let c = captures()[0]
        XCTAssertEqual(BevelCapture(event: c.event), c)
        XCTAssertNil(BevelCapture(event: WhoopEvent(ts: 600, kind: "OTHER", payload: [:])))
    }
    func testConstantIntervalsAreZeroSDNN() {
        let c = captures().map { BevelCapture(id: $0.id, session: $0.session, receivedAt: $0.receivedAt, bytes: bytes()) }
        XCTAssertEqual(plan(c).samples.last?.value, 0)
    }
}
