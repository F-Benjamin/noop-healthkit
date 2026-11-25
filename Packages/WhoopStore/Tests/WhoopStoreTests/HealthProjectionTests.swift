import XCTest
import WhoopProtocol
@testable import WhoopStore

final class HealthProjectionTests: XCTestCase {
    private let hrPolicy = HealthKitProjectionPolicy(mode: .downsample, minimumInterval: 60,
                                                      maxSamplesPerHour: 60, maxSamplesPerDay: 1_440)

    func testOneHourAtOneHertzProjectsAtMostSixtyRealSamples() {
        let rows = (0..<3_600).map { second in
            HealthMeasurement(id: "hr:\(second)", metric: .heartRate,
                startTs: Double(second), endTs: Double(second), value: Double(60 + second % 30),
                unit: .countPerMinute, deviceId: "strap", source: .measuredDevice, quality: .valid)
        }
        let result = HealthProjectionSelector.select(rows, policy: hrPolicy)
        XCTAssertEqual(result.selected.count, 60)
        XCTAssertEqual(result.suppressed.count, 3_540)
        XCTAssertTrue(result.selected.allSatisfy(rows.contains))
        XCTAssertEqual(Set(result.selected.map(\.id)).count, result.selected.count)
    }

    func testRestartDoesNotSelectAnOccupiedMinuteAgain() {
        let rows = (0..<60).map { second in
            HealthMeasurement(id: "hr:\(second)", metric: .heartRate,
                startTs: Double(second), endTs: Double(second), value: 70,
                unit: .countPerMinute, deviceId: "strap", source: .measuredDevice, quality: .valid)
        }
        let result = HealthProjectionSelector.select(rows, policy: hrPolicy, occupiedBuckets: [0])
        XCTAssertTrue(result.selected.isEmpty)
        XCTAssertEqual(result.suppressed.count, 60)
    }

    func testFortyEightHourBackfillIsDeterministicAndBounded() {
        var rows: [HealthMeasurement] = []
        rows.reserveCapacity(48 * 3_600)
        for second in 0..<(48 * 3_600) {
            let timestamp = Double(second)
            let bpm = Double(55 + (second % 50))
            rows.append(HealthMeasurement(id: "hr:\(second)", metric: .heartRate,
                startTs: timestamp, endTs: timestamp, value: bpm, unit: .countPerMinute,
                deviceId: "strap", source: .measuredDevice, quality: .valid))
        }
        let first = HealthProjectionSelector.select(rows, policy: hrPolicy)
        let second = HealthProjectionSelector.select(Array(rows.reversed()), policy: hrPolicy)
        XCTAssertEqual(first.selected.count, 48 * 60)
        XCTAssertEqual(first.selected.map { $0.id }, second.selected.map { $0.id })

        // Simulate bounded 20-minute processing, interruption and restart. Persisted occupied
        // buckets stand in for written canonical state and prevent any replay.
        var occupied = Set<Int64>()
        var exported: [String] = []
        for chunkStart in stride(from: 0, to: rows.count, by: 1_200) {
            let chunk = Array(rows[chunkStart..<min(chunkStart + 1_200, rows.count)])
            let projected = HealthProjectionSelector.select(chunk, policy: hrPolicy,
                                                             occupiedBuckets: occupied)
            exported.append(contentsOf: projected.selected.map { $0.id })
            occupied.formUnion(projected.selected.map { Int64(floor($0.startTs / 60)) })
        }
        XCTAssertEqual(exported.count, 48 * 60)
        XCTAssertEqual(Set(exported).count, exported.count)
        let replay = HealthProjectionSelector.select(rows, policy: hrPolicy,
                                                      occupiedBuckets: occupied)
        XCTAssertTrue(replay.selected.isEmpty)
    }

    func testCanonicalStateSurvivesDuplicateAndCorrection() async throws {
        let store = try await WhoopStore.inMemory()
        var row = HealthMeasurement(id: "stable", metric: .heartRate, startTs: 10, endTs: 10,
            value: 70, unit: .countPerMinute, deviceId: "strap", source: .measuredDevice, quality: .valid)
        try await store.upsertHealthMeasurements([row])
        try await store.markHealthMeasurements([row.id], status: .written, writtenAt: 20)
        try await store.upsertHealthMeasurements([row])
        let afterReplay = try await store.pendingHealthMeasurements(metric: .heartRate, deviceId: "strap", limit: 10)
        XCTAssertTrue(afterReplay.isEmpty)
        row.value = 71
        try await store.upsertHealthMeasurements([row])
        let pending = try await store.pendingHealthMeasurements(metric: .heartRate, deviceId: "strap", limit: 10)
        XCTAssertEqual(pending.first?.value, 71)
        XCTAssertEqual(pending.first?.healthKitSyncVersion, 2)
    }

    func testOneHourAtOneHertzKeepsRawHRButOnlySixtyPending() async throws {
        let store = try await WhoopStore.inMemory()
        let source = (0..<3_600).map { HRSample(ts: $0, bpm: 60 + $0 % 30) }
        _ = try await store.insert(Streams(hr: source), deviceId: "strap")
        let rows = source.map { sample in
            HealthMeasurement(id: "hr:\(sample.ts)", metric: .heartRate,
                startTs: Double(sample.ts), endTs: Double(sample.ts), value: Double(sample.bpm),
                unit: .countPerMinute, deviceId: "strap", source: .measuredDevice,
                quality: .valid, rateContext: .background)
        }
        try await store.upsertProjectedHealthMeasurements(rows)

        let raw = try await store.hrSamples(deviceId: "strap", from: 0, to: 3_599, limit: 4_000)
        let counts = try await store.healthKitStatusCounts(deviceId: "strap")
        XCTAssertEqual(raw.count, 3_600)
        XCTAssertEqual(counts[.pending], 60)
        XCTAssertEqual(counts[.suppressedByProjectionPolicy], 3_540)
        XCTAssertEqual(counts[.written, default: 0], 0)
    }

    func testTwentyFourHoursAndThirtyDaysRemainAtOneCandidatePerMinute() {
        for days in [1, 30] {
            var selected = 0
            var suppressed = 0
            for hour in 0..<(days * 24) {
                let base = hour * 3_600
                let rows = (0..<3_600).map { second in
                    HealthMeasurement(id: "hr:\(base + second)", metric: .heartRate,
                        startTs: Double(base + second), endTs: Double(base + second), value: 70,
                        unit: .countPerMinute, deviceId: "strap", source: .measuredDevice,
                        quality: .valid, rateContext: .background)
                }
                let result = HealthProjectionSelector.select(rows, policy: hrPolicy)
                selected += result.selected.count
                suppressed += result.suppressed.count
            }
            XCTAssertEqual(selected, days * 24 * 60)
            XCTAssertEqual(suppressed, days * 24 * 3_540)
        }
    }

    func testRestartAndRenormalizationNeverRequeueSuppressedRows() async throws {
        let store = try await WhoopStore.inMemory()
        let rows = (0..<3_600).map { second in
            HealthMeasurement(id: "hr:\(second)", metric: .heartRate,
                startTs: Double(second), endTs: Double(second), value: 70,
                unit: .countPerMinute, deviceId: "strap", source: .measuredDevice,
                quality: .valid, rateContext: .background)
        }
        try await store.upsertProjectedHealthMeasurements(rows)
        let first = try await store.healthKitStatusCounts(deviceId: "strap")
        try await store.upsertProjectedHealthMeasurements(Array(rows.reversed()))
        _ = try await store.reprojectHealthMeasurements(metric: .heartRate, deviceId: "strap")
        let replay = try await store.healthKitStatusCounts(deviceId: "strap")
        XCTAssertEqual(replay[.pending], first[.pending])
        XCTAssertEqual(replay[.suppressedByProjectionPolicy], first[.suppressedByProjectionPolicy])
        XCTAssertEqual(replay[.written, default: 0], 0)
    }

    func testContextPoliciesAreIndependent() {
        let rows = (0..<3_600).map { second in
            HealthMeasurement(id: "hr:\(second)", metric: .heartRate,
                startTs: Double(second), endTs: Double(second), value: 70,
                unit: .countPerMinute, deviceId: "strap", source: .measuredDevice,
                quality: .valid)
        }
        let expected: [(HealthRateContext, Int)] = [(.background, 60), (.sleep, 120),
                                                    (.workout, 720), (.manual, 3_600),
                                                    (.historicalBackfill, 60)]
        for (context, count) in expected {
            let policy = HealthProjectionPolicies.policy(for: .heartRate, context: context)
            XCTAssertEqual(HealthProjectionSelector.select(rows, policy: policy).selected.count, count)
        }
    }

    func testExplicitPolicyChangeReprojectsWithoutWriting() async throws {
        let store = try await WhoopStore.inMemory()
        let rows = (0..<3_600).map { second in
            HealthMeasurement(id: "hr:\(second)", metric: .heartRate,
                startTs: Double(second), endTs: Double(second), value: 70,
                unit: .countPerMinute, deviceId: "strap", source: .measuredDevice,
                quality: .valid, rateContext: .background)
        }
        try await store.upsertProjectedHealthMeasurements(rows)
        let thirtySeconds = HealthKitProjectionPolicy(mode: .downsample, minimumInterval: 30,
                                                       maxSamplesPerHour: 120)
        _ = try await store.reprojectHealthMeasurements(metric: .heartRate, deviceId: "strap",
                                                        policy: thirtySeconds)
        var counts = try await store.healthKitStatusCounts(deviceId: "strap")
        XCTAssertEqual(counts[.pending], 120)
        XCTAssertEqual(counts[.written, default: 0], 0)
        _ = try await store.reprojectHealthMeasurements(metric: .heartRate, deviceId: "strap",
                                                        policy: hrPolicy)
        counts = try await store.healthKitStatusCounts(deviceId: "strap")
        XCTAssertEqual(counts[.pending], 60)
        XCTAssertEqual(counts[.suppressedByProjectionPolicy], 3_540)
        XCTAssertEqual(counts[.written, default: 0], 0)
    }
}
