import Foundation
import WhoopProtocol
import WhoopStore

// Deterministic smoke test runnable with Command Line Tools (no XCTest/iOS SDK).
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
}
func packet(_ raw: Int = 1024, flags: UInt8 = 0x16) -> [UInt8] {
    [flags, 60, UInt8(raw & 255), UInt8(raw >> 8)]
}
let captures = (0..<60).map { i in
    BevelCapture(id: "p\(i)", session: "session1", receivedAt: Double(600 + i),
                 bytes: packet(i % 2 == 0 ? 1000 : 1048))
}
func plan(_ c: [BevelCapture]) -> BevelExport.Plan {
    BevelExport.plan(captures: c, deviceID: "strap-A", minute: 600, now: 665)
}
let result = plan(captures)
check(result.samples.count == 61, "60 HR + 1 SDNN")
check(abs(result.samples.last!.value - sqrt(60 * pow(23.4375, 2) / 59)) < 1e-10, "Sample SD denominator n-1")
check(result.samples.last!.acceptedBeats == 60, "All clean beats retained")
check(plan(captures + captures).samples == result.samples, "Replay identity")
check(plan(captures.reversed()).samples == result.samples, "Input ordering")
check(BevelCapture(event: captures[0].event) == captures[0], "Durable event round trip")
let precise = BevelExport.parse([0x1F, 44, 1, 255, 255, 1, 4, 0, 4])!
check(precise.bpm == 300 && precise.rrMS == [1000.9765625, 1000], "16-bit HR, energy, RR precision")
for bytes: [UInt8] in [[], [0], [1, 60], [8, 60], [8, 60, 0], [16, 60], [16, 60, 0], [0, 60, 0], [0x80, 60]] {
    check(BevelExport.parse(bytes) == nil, "Reject malformed packet \(bytes)")
}
let noRR = captures.map { BevelCapture(id: $0.id, session: $0.session, receivedAt: $0.receivedAt, bytes: [0, 60]) }
check(plan(noRR).samples.count == 60 && plan(noRR).samples.allSatisfy { $0.kind == .heartRate }, "HR alone cannot manufacture HRV")
let off = captures.map { BevelCapture(id: $0.id, session: $0.session, receivedAt: $0.receivedAt, bytes: packet(flags: 0x14)) }
check(plan(off).samples.isEmpty, "Off wrist")
let gap = captures.filter { !(620...630).contains(Int($0.receivedAt)) }
check(!plan(gap).samples.contains { $0.kind == .sdnn }, "Gap refuses SDNN")
var reconnect = captures
reconnect[30] = BevelCapture(id: "reconnect", session: "session2", receivedAt: 630, bytes: packet())
check(!plan(reconnect).samples.contains { $0.kind == .sdnn }, "Reconnect refuses SDNN")
let duplicateBeats = captures.map { BevelCapture(id: $0.id, session: $0.session, receivedAt: $0.receivedAt, bytes: packet() + [0, 4]) }
check(!plan(duplicateBeats).samples.contains { $0.kind == .sdnn }, "Overcount refuses SDNN")
let artifacts = captures.enumerated().map { i, p in BevelCapture(id: p.id, session: p.session, receivedAt: p.receivedAt, bytes: packet(i % 4 == 0 ? 2000 : 1024)) }
check(!plan(artifacts).samples.contains { $0.kind == .sdnn }, "Artifacts refuse SDNN")
let sparseRR = captures.enumerated().map { i, p in
    BevelCapture(id: p.id, session: p.session, receivedAt: p.receivedAt,
                 bytes: i == 10 || i == 20 ? [0x06, 60] : p.bytes)
}
check(plan(sparseRR).samples.contains { $0.kind == .sdnn }, "Isolated HR-only packets do not invalidate measured RR coverage")
let constant = captures.map { BevelCapture(id: $0.id, session: $0.session, receivedAt: $0.receivedAt, bytes: packet()) }
check(plan(constant).samples.last?.value == 0, "Constant RR = zero SDNN")
check(BevelExport.plan(captures: captures, deviceID: "a", minute: 600, now: 664).samples.isEmpty, "Wait for completed window")
check(BevelExport.plan(captures: captures, deviceID: "b", minute: 600, now: 665).samples.last?.id != result.samples.last?.id, "Separate devices")
print("PASS: \(checks) Bevel checks; reference SDNN = \(result.samples.last!.value) ms")

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("bevel-check-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let db = try await WhoopStore(path: temp.appendingPathComponent("test.sqlite").path)
try await db.upsertDevice(id: "strap-A", mac: nil, name: "Test")
try await db.upsertDevice(id: "strap-B", mac: nil, name: "Other")
let stream = Streams(events: captures.map(\.event))
_ = try await db.insert(stream, deviceId: "strap-A")
_ = try await db.insert(stream, deviceId: "strap-A")
_ = try await db.insert(stream, deviceId: "strap-B")
let loaded = try await db.bevelCaptures(deviceId: "strap-A", from: 600, to: 660)
check(loaded.count == 60, "SQLite retries do not duplicate packets")
check(plan(loaded).samples == result.samples, "SQLite preserves RR provenance and order")
let first = try await db.firstBevelCaptureTimestamp(deviceId: "strap-A")
check(first == 600, "Initial export starts at first recorded packet")
let none = try await db.bevelCaptures(deviceId: "unknown", from: 600, to: 660)
check(none.isEmpty, "SQLite device isolation")
let sameSecond = BevelCapture(id: "same-second", session: "session1", receivedAt: 600.5, bytes: packet())
_ = try await db.insert(Streams(events: [sameSecond.event]), deviceId: "strap-A")
let preserved = try await db.bevelCaptures(deviceId: "strap-A", from: 600, to: 601)
check(preserved.count == 2, "Distinct notifications within one second survive")
print("PASS: \(checks) total checks including actual SQLite insertion, replay, isolation, and readback")

// Optional field replay: run the exact production planner over a copied iPhone database.
if let fieldPath = ProcessInfo.processInfo.environment["BEVEL_DB_PATH"],
   let fieldDevice = ProcessInfo.processInfo.environment["BEVEL_DEVICE_ID"] {
    let fieldDB = try await WhoopStore(path: fieldPath)
    if let firstField = try await fieldDB.firstBevelCaptureTimestamp(deviceId: fieldDevice) {
        let now = Date().timeIntervalSince1970
        let start = firstField / 60 * 60
        let end = Int((now - 5) / 60) * 60
        let fieldCaptures = try await fieldDB.bevelCaptures(deviceId: fieldDevice, from: start, to: end)
        let grouped = Dictionary(grouping: fieldCaptures, by: { Int($0.receivedAt) / 60 * 60 })
        for minute in stride(from: start, to: end, by: 60) {
            let fieldPlan = BevelExport.plan(captures: grouped[minute] ?? [], deviceID: fieldDevice,
                                             minute: minute, now: now)
            for sample in fieldPlan.samples where sample.kind == .sdnn {
                print("FIELD SDNN minute=\(minute) value=\(sample.value) accepted=\(sample.acceptedBeats) rejected=\(sample.rejectedBeats)")
            }
        }
    }
}
