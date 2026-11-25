import XCTest
import WhoopProtocol
@testable import WhoopStore

final class HeartRateRetentionTests: XCTestCase {
    private func seedProjectedHour(store: WhoopStore, device: String, start: Int,
                                   context: HealthRateContext = .background) async throws {
        let source = (0..<3_600).map { HRSample(ts: start + $0, bpm: 60 + $0 % 30) }
        _ = try await store.insert(Streams(hr: source), deviceId: device)
        let canonical = source.map { sample in
            HealthMeasurement(id: "\(device):hr:\(sample.ts):\(context.rawValue)", metric: .heartRate,
                startTs: Double(sample.ts), endTs: Double(sample.ts), value: Double(sample.bpm),
                unit: .countPerMinute, deviceId: device, source: .measuredDevice,
                quality: .valid, rateContext: context)
        }
        try await store.upsertProjectedHealthMeasurements(canonical)
    }

    func testOldBackgroundExcessIsPurgedOnlyAfterCandidateWasWritten() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "strap"
        try await seedProjectedHour(store: store, device: device, start: 3_600)

        var pending = try await store.pendingHealthMeasurements(metric: .heartRate,
                                                                 deviceId: device, limit: 100)
        XCTAssertEqual(pending.count, 60)
        // Until every minute's candidate is successful, its 59 suppressed seconds remain protected.
        _ = try await store.maintainHeartRateRetention(deviceId: device, now: 100_000,
                                                       maxRows: 5_000, force: true)
        var raw = try await store.hrSamples(deviceId: device, from: 0, to: 10_000, limit: 4_000)
        XCTAssertEqual(raw.count, 3_600)

        try await store.markHealthMeasurements(pending.map(\.id), status: .written, writtenAt: 90_000)
        let result = try await store.maintainHeartRateRetention(deviceId: device, now: 100_000,
                                                                maxRows: 5_000, force: true)
        XCTAssertEqual(result.deletedRows, 3_540)
        raw = try await store.hrSamples(deviceId: device, from: 0, to: 10_000, limit: 4_000)
        XCTAssertEqual(raw.count, 60)
        pending = try await store.pendingHealthMeasurements(metric: .heartRate,
                                                             deviceId: device, limit: 100)
        XCTAssertTrue(pending.isEmpty)
    }

    func testSafetyWindowAndPendingFailedRowsSurvive() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "strap"
        try await seedProjectedHour(store: store, device: device, start: 3_600)
        let candidates = try await store.pendingHealthMeasurements(metric: .heartRate,
                                                                    deviceId: device, limit: 100)
        try await store.markHealthMeasurements(Array(candidates.dropFirst()).map(\.id),
                                                status: .written, writtenAt: 90_000)
        try await store.markHealthMeasurements([candidates[0].id], status: .failed,
                                                error: "temporary")

        let oldRun = try await store.maintainHeartRateRetention(deviceId: device, now: 100_000,
                                                                maxRows: 10_000, force: true)
        XCTAssertEqual(oldRun.deletedRows, 59 * 59)
        XCTAssertGreaterThanOrEqual(oldRun.protectedRows, 1)

        try await seedProjectedHour(store: store, device: device, start: 99_000)
        let withinWindow = try await store.maintainHeartRateRetention(deviceId: device, now: 100_100,
                                                                      maxRows: 10_000, force: true)
        XCTAssertEqual(withinWindow.deletedRows, 0)
    }

    func testContextProjectionControlsPermanentResolution() async throws {
        for (context, expected) in [(HealthRateContext.background, 60), (.sleep, 120), (.workout, 720)] {
            let store = try await WhoopStore.inMemory()
            try await seedProjectedHour(store: store, device: "strap", start: 3_600, context: context)
            let candidates = try await store.pendingHealthMeasurements(metric: .heartRate,
                                                                        deviceId: "strap", limit: 1_000)
            XCTAssertEqual(candidates.count, expected)
            try await store.markHealthMeasurements(candidates.map(\.id), status: .written, writtenAt: 90_000)
            _ = try await store.maintainHeartRateRetention(deviceId: "strap", now: 100_000,
                                                            maxRows: 5_000, force: true)
            let raw = try await store.hrSamples(deviceId: "strap", from: 0, to: 10_000, limit: 4_000)
            XCTAssertEqual(raw.count, expected)
        }
    }

    func testThirtyDayOneHertzModelReachesStableBound() {
        let total = 30 * 24 * 3_600
        let safetyWindow = 24 * 3_600
        let durableBackground = 29 * 24 * 60
        let retained = safetyWindow + durableBackground
        XCTAssertEqual(total, 2_592_000)
        XCTAssertEqual(retained, 128_160)
        XCTAssertLessThan(retained, total / 20)

        // Advancing one day adds one new 1 Hz window while compacting yesterday to 1/min.
        let nextDay = safetyWindow + 30 * 24 * 60
        XCTAssertEqual(nextDay - retained, 1_440)
    }

    func testMaintenanceIsBoundedAndThrottledAcrossRelaunchEquivalent() async throws {
        let store = try await WhoopStore.inMemory()
        try await seedProjectedHour(store: store, device: "strap", start: 3_600)
        let candidates = try await store.pendingHealthMeasurements(metric: .heartRate,
                                                                    deviceId: "strap", limit: 100)
        try await store.markHealthMeasurements(candidates.map(\.id), status: .written, writtenAt: 90_000)
        let first = try await store.maintainHeartRateRetention(deviceId: "strap", now: 100_000,
                                                               maxRows: 100, force: true)
        XCTAssertEqual(first.deletedRows, 100)
        let throttled = try await store.maintainHeartRateRetention(deviceId: "strap", now: 100_100,
                                                                   maxRows: 100)
        XCTAssertFalse(throttled.ran)
        let resumed = try await store.maintainHeartRateRetention(deviceId: "strap", now: 103_601,
                                                                 maxRows: 100)
        XCTAssertTrue(resumed.ran)
        XCTAssertEqual(resumed.deletedRows, 100)
    }
}
