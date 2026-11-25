import XCTest
@testable import WhoopStore

final class HealthExportSafetyTests: XCTestCase {
    private func row(metric: HealthMetric = .heartRate, ts: Double = 1_800_000_000,
                     value: Double? = 70, source: MeasurementSource = .measuredDevice) -> HealthMeasurement {
        HealthMeasurement(id: "stable-source:42", metric: metric, startTs: ts, endTs: ts,
                          value: value, unit: .countPerMinute, deviceId: "strap",
                          source: source, quality: .valid, sourceSequence: 42,
                          sourceIdentifier: "whoop-vendor-stream", clockEpoch: "boot-7")
    }

    func testHundredThousandPendingTripsBeforeBatching() {
        let load = HealthExportLoad(metric: .heartRate, pending: 100_000, source: 0, selected: 0,
                                    retries: 0, outputLastHour: 0, outputLastDay: 0,
                                    previousHourOutput: 0)
        XCTAssertNotNil(HealthExportSafetyPolicy.breakerReason(for: load))
    }

    func testBreakerSurvivesEncodingRoundTrip() throws {
        let original = HealthCircuitBreakerSnapshot(tripped: true, reason: "queue", timestamp: 12,
                                                    metric: .heartRate)
        XCTAssertEqual(try JSONDecoder().decode(HealthCircuitBreakerSnapshot.self,
                                                from: JSONEncoder().encode(original)), original)
    }

    func testBackfillProgressAndCancellationArePersistentValues() throws {
        var plan = HealthBackfillPlan(start: 0, end: 365 * 86_400)
        for _ in 0..<(365 * 72) { plan.advance(to: plan.cursor + 1_200) }
        XCTAssertTrue(plan.isComplete)
        plan.cancelled = true
        let restored = try JSONDecoder().decode(HealthBackfillPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(restored, plan)
    }

    func testChunkPlanCommitsOnlyWholeBoundedChunks() {
        let chunks = HealthBatchCommitPlanner.chunks(Array(0..<61), size: 25)
        XCTAssertEqual(chunks.map(\.count), [25, 25, 11])
        XCTAssertEqual(chunks[0], Array(0..<25))
    }

    func testPartialBatchFailureKeepsFirstChunkCommittedForRestart() async {
        enum Expected: Error { case failed }
        var committed: [Int] = []
        var calls = 0
        do {
            try await HealthBatchCommitPlanner.execute(Array(0..<60), size: 25, save: { _ in
                calls += 1; if calls == 2 { throw Expected.failed }
            }, commit: { committed += $0 })
            XCTFail("second chunk should fail")
        } catch Expected.failed { }
        catch { XCTFail("unexpected error \(error)") }
        XCTAssertEqual(committed, Array(0..<25))
        XCTAssertEqual(Array(25..<60).count, 35)
    }

    func testBackfillDurationsRemainBoundedAndComplete() {
        for days in [1, 7, 30, 365] {
            var p = HealthBackfillPlan(start: 0, end: days * 86_400)
            var peakSlice = 0
            while !p.isComplete {
                let next = min(p.end, p.cursor + 1_200)
                peakSlice = max(peakSlice, next - p.cursor); p.advance(to: next)
            }
            XCTAssertEqual(p.cursor, days * 86_400)
            XCTAssertLessThanOrEqual(peakSlice, 1_200)
        }
    }

    func testFinalValidationRejectsCorruptAndUntrustedSamples() {
        XCTAssertNotNil(HealthSampleValidation.rejectionReason(row(ts: -1), now: 1_800_000_000))
        XCTAssertNotNil(HealthSampleValidation.rejectionReason(row(ts: 2_500_000_000), now: 1_800_000_000))
        var inverted = row(); inverted.endTs = inverted.startTs - 1
        XCTAssertNotNil(HealthSampleValidation.rejectionReason(inverted, now: 1_900_000_000))
        let spo2 = row(metric: .oxygenSaturation, value: 0.95, source: .estimatedByNoop)
        XCTAssertNotNil(HealthSampleValidation.rejectionReason(spo2, now: 1_900_000_000))
    }

    func testOwnedObjectPreventsReplayInFreshCanonicalQueue() async throws {
        let store = try await WhoopStore.inMemory()
        let r = row()
        try await store.replaceHealthKitOwnership([.init(syncIdentifier: r.id,
                                                          healthKitUUID: "existing-hk-uuid",
                                                          sampleType: "HKQuantityTypeIdentifierHeartRate",
                                                          startTs: r.startTs, endTs: r.endTs)])
        try await store.upsertHealthMeasurements([r])
        let pending = try await store.pendingHealthMeasurements(metric: .heartRate,
                                                                 deviceId: "strap", limit: 10)
        XCTAssertTrue(pending.isEmpty)
    }

    func testAuthorizationRestoreRequeuesOnlyNewEpoch() async throws {
        let store = try await WhoopStore.inMemory()
        var old = row(ts: 1_700_000_000); old.id = "old"
        var fresh = row(ts: 1_800_000_000); fresh.id = "fresh"
        try await store.upsertHealthMeasurements([old, fresh])
        try await store.markHealthMeasurements([old.id, fresh.id], status: .unauthorized)
        try await store.requeueUnauthorizedHealthKitWrites(deviceId: "strap", notBefore: 1_750_000_000)
        let pending = try await store.pendingHealthMeasurements(metric: .heartRate, deviceId: "strap", limit: 10)
        XCTAssertEqual(pending.map(\.id), ["fresh"])
    }

    func testPersistedDayIsStableAcrossDSTAndTravel() throws {
        let before = TimeZone.ReferenceType.default
        defer { TimeZone.ReferenceType.default = before }
        TimeZone.ReferenceType.default = TimeZone(identifier: "Europe/Paris")!
        let paris = try XCTUnwrap(HealthTimestampSemantics.utcDayBounds("2026-03-29"))
        TimeZone.ReferenceType.default = TimeZone(identifier: "America/Los_Angeles")!
        let losAngeles = try XCTUnwrap(HealthTimestampSemantics.utcDayBounds("2026-03-29"))
        XCTAssertEqual(paris.start, losAngeles.start)
        XCTAssertEqual(paris.end - paris.start, 86_400)
    }

    func testAuthorizationNotDeterminedRequestThenReconciliationTransitionsExplicitly() {
        XCTAssertTrue(HealthReconciliationStateMachine.canTransition(from: .required, to: .requestingAuthorization))
        XCTAssertTrue(HealthReconciliationStateMachine.canTransition(from: .requestingAuthorization, to: .reconciling))
        XCTAssertTrue(HealthReconciliationStateMachine.canTransition(from: .reconciling, to: .reconciled))
    }

    func testCancelledAuthorizationReturnsToRequired() {
        XCTAssertTrue(HealthReconciliationStateMachine.canTransition(from: .requestingAuthorization, to: .failedRecoverable))
        XCTAssertTrue(HealthReconciliationStateMachine.canTransition(from: .failedRecoverable, to: .required))
    }

    func testKilledTransientReconciliationRecoversToRequiredOnLaunch() {
        XCTAssertEqual(HealthReconciliationStateMachine.recoveredAfterLaunch(.reconciling), .required)
        XCTAssertEqual(HealthReconciliationStateMachine.recoveredAfterLaunch(.requestingAuthorization), .required)
        XCTAssertEqual(HealthReconciliationStateMachine.recoveredAfterLaunch(.failedRecoverable), .required)
    }

    func testZeroOwnedObjectsSelectsNewEpochOnlyTransition() {
        XCTAssertTrue(HealthReconciliationStateMachine.canTransition(from: .reconciling, to: .newEpochOnly))
    }

    func test1433HistoricalPendingRowsAreIneligibleAfterNewEpoch() async throws {
        let store = try await WhoopStore.inMemory()
        let rows = (0..<1_433).map { index in
            HealthMeasurement(id: "historical:\(index)", metric: .heartRate,
                              startTs: 1_700_000_000 + Double(index),
                              endTs: 1_700_000_000 + Double(index), value: 70,
                              unit: .countPerMinute, deviceId: "strap", source: .measuredDevice,
                              quality: .valid, sourceSequence: Int64(index),
                              sourceIdentifier: "whoop-stream", clockEpoch: "boot-1")
        }
        try await store.upsertHealthMeasurements(rows)
        let eligible = try await store.pendingHealthMeasurements(
            metric: .heartRate, deviceId: "strap", limit: 2_000, notBefore: 1_800_000_000)
        let excluded = try await store.healthMeasurementCount(
            deviceId: "strap", statuses: [.pending], before: 1_800_000_000)
        XCTAssertTrue(eligible.isEmpty)
        XCTAssertEqual(excluded, 1_433)
    }

    func testAdvancingBoundaryExpiresOldQueueAndRenormalizationCannotRequeueIt() async throws {
        let store = try await WhoopStore.inMemory()
        var old = row(ts: 100); old.id = "old"
        var fresh = row(ts: 200); fresh.id = "fresh"
        try await store.upsertHealthMeasurements([old, fresh])
        let expired = try await store.expireHealthMeasurements(deviceId: "strap", before: 150)
        let firstOldStatus = try await store.healthMeasurement(id: "old")?.healthKitStatus
        XCTAssertEqual(expired, 1)
        XCTAssertEqual(firstOldStatus, .expiredByExportBoundary)
        old.value = 71
        try await store.upsertHealthMeasurements([old])
        let replayedOldStatus = try await store.healthMeasurement(id: "old")?.healthKitStatus
        XCTAssertEqual(replayedOldStatus, .expiredByExportBoundary)
        let pending = try await store.pendingHealthMeasurements(metric: .heartRate,
                                                                 deviceId: "strap", limit: 10,
                                                                 notBefore: 150)
        XCTAssertEqual(pending.map(\.id), ["fresh"])
    }

    func testCircuitBreakerLoadCountsOnlyExportableSideOfBoundary() async throws {
        let store = try await WhoopStore.inMemory()
        let oldRows = (0..<100).map { index in
            HealthMeasurement(id: "old:\(index)", metric: .heartRate,
                              startTs: Double(index), endTs: Double(index), value: 70,
                              unit: .countPerMinute, deviceId: "strap", source: .measuredDevice,
                              quality: .valid)
        }
        var fresh = row(ts: 1_000); fresh.id = "fresh"
        try await store.upsertHealthMeasurements(oldRows + [fresh])
        let load = try await store.healthExportLoad(metric: .heartRate, deviceId: "strap",
                                                    now: 2_000, notBefore: 500)
        XCTAssertEqual(load.pending, 1)
        XCTAssertNil(HealthExportSafetyPolicy.breakerReason(for: load))
    }

    func testPreBoundaryTombstoneCannotReachDeletionQueue() async throws {
        let store = try await WhoopStore.inMemory()
        var old = row(ts: 100); old.id = "old"
        var fresh = row(ts: 200); fresh.id = "fresh"
        try await store.upsertHealthMeasurements([old, fresh])
        try await store.markHealthMeasurements([old.id, fresh.id], status: .pendingDeletion)
        let eligible = try await store.pendingHealthKitDeletions(metric: .heartRate,
                                                                 deviceId: "strap", limit: 10,
                                                                 notBefore: 150)
        XCTAssertEqual(eligible.map(\.id), ["fresh"])
    }

    func testFixedRecoveryFloorDoesNotInvalidateMeasurementAcrossMidnight() async throws {
        let store = try await WhoopStore.inMemory()
        var beforeMidnight = row(ts: 1_789_164_740); beforeMidnight.id = "23:59"
        var afterMidnight = row(ts: 1_789_164_860); afterMidnight.id = "00:01"
        try await store.upsertHealthMeasurements([beforeMidnight, afterMidnight])
        let eligible = try await store.pendingHealthMeasurements(metric: .heartRate,
            deviceId: "strap", limit: 10, notBefore: 1_789_077_600)
        XCTAssertEqual(eligible.map(\.id), ["23:59", "00:01"])
    }

    func testStaleHRQueueExpiresWithoutTouchingOtherMetricsOrLocalHR() async throws {
        let store = try await WhoopStore.inMemory()
        var staleHR = row(ts: 100); staleHR.id = "stale-hr"
        var freshHR = row(ts: 1_000); freshHR.id = "fresh-hr"
        let hrv = HealthMeasurement(id: "old-hrv", metric: .heartRateVariabilitySDNN,
            startTs: 100, endTs: 160, value: 45, unit: .millisecond, deviceId: "strap",
            source: .derivedByNoop, quality: .valid)
        try await store.upsertHealthMeasurements([staleHR, freshHR, hrv])
        let changed = try await store.expireHealthMeasurements(metric: .heartRate,
                                                                deviceId: "strap", before: 500)
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(try await store.healthMeasurement(id: "stale-hr")?.healthKitStatus,
                       .expiredByExportBoundary)
        XCTAssertEqual(try await store.healthMeasurement(id: "fresh-hr")?.healthKitStatus, .pending)
        XCTAssertEqual(try await store.healthMeasurement(id: "old-hrv")?.healthKitStatus, .pending)
    }

    func testOneShotSleepRecoveryCannotReviveAnotherMetricOrOutsideRow() async throws {
        let store = try await WhoopStore.inMemory()
        let sleep = HealthMeasurement(id: "sleep", metric: .sleepStage, startTs: 100, endTs: 200,
            value: nil, unit: nil, categoryValue: HealthSleepStage.core.rawValue, deviceId: "strap",
            source: .derivedByNoop, quality: .valid)
        var hr = row(ts: 150); hr.id = "hr"
        try await store.upsertHealthMeasurements([sleep, hr])
        _ = try await store.expireHealthMeasurements(deviceId: "strap", before: 300)
        do {
            _ = try await store.authorizeOneShotSleepRecovery(["sleep", "hr"], deviceId: "strap",
                windowStart: 100, windowEnd: 200)
            XCTFail("mixed metrics must be rejected atomically")
        } catch { }
        let rejectedSleep = try await store.healthMeasurement(id: "sleep")?.healthKitStatus
        let rejectedHR = try await store.healthMeasurement(id: "hr")?.healthKitStatus
        XCTAssertEqual(rejectedSleep, .expiredByExportBoundary)
        XCTAssertEqual(rejectedHR, .expiredByExportBoundary)
        let authorized = try await store.authorizeOneShotSleepRecovery(["sleep"], deviceId: "strap",
            windowStart: 100, windowEnd: 200)
        let authorizedSleep = try await store.healthMeasurement(id: "sleep")?.healthKitStatus
        let stillExpiredHR = try await store.healthMeasurement(id: "hr")?.healthKitStatus
        XCTAssertEqual(authorized, 1)
        XCTAssertEqual(authorizedSleep, .pending)
        XCTAssertEqual(stillExpiredHR, .expiredByExportBoundary)
    }

    func testRecoveredSleepMarkerSurvivesNormalSnapshotReconciliation() async throws {
        let store = try await WhoopStore.inMemory()
        var sleep = HealthMeasurement(id: "protected", metric: .sleepStage, startTs: 150, endTs: 200,
            value: nil, unit: nil, categoryValue: HealthSleepStage.deep.rawValue, deviceId: "strap",
            source: .derivedByNoop, quality: .valid)
        sleep.metadataJSON = "{\"oneShotSleepRecovery\":\"target\"}"
        try await store.upsertHealthMeasurements([sleep])
        try await store.markHealthMeasurements([sleep.id], status: .written,
                                               writtenAt: 300, healthKitUUID: "uuid")
        let reconciled = try await store.reconcileHealthMeasurementSnapshot(metric: .sleepStage,
            deviceId: "strap", from: 100, to: 250, currentIdentifiers: [])
        XCTAssertEqual(reconciled, 0)
        let status = try await store.healthMeasurement(id: sleep.id)?.healthKitStatus
        XCTAssertEqual(status, .written)
    }
}
