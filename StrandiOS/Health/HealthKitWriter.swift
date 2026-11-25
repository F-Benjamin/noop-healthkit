#if os(iOS)
import Foundation
import HealthKit
import WhoopStore

@MainActor
final class HealthKitWriter {
    struct CircuitBreakerError: LocalizedError {
        let reason: String
        var errorDescription: String? { "HealthKit circuit breaker: \(reason)" }
    }
    struct SaveTimeout: LocalizedError {
        let sampleCount: Int
        var errorDescription: String? { "Apple Health did not answer within 20 seconds while saving \(sampleCount) samples." }
    }

    let store: HKHealthStore
    private let client: HealthKitClient
    init(store: HKHealthStore) {
        self.store = store
        self.client = SystemHealthKitClient(store: store)
    }
    init(client: HealthKitClient) { self.client = client; self.store = client.healthStore }

    func write(_ measurements: [HealthMeasurement], definition: HealthKitMetricDefinition,
               device: HKDevice?, repository: WhoopStore) async throws -> Int {
        guard !measurements.isEmpty else { return 0 }
        guard definition.writable else {
            try await repository.markHealthMeasurements(measurements.map(\.id), status: .unsupported)
            return 0
        }
        let now = Date().timeIntervalSince1970
        let sourceValid = measurements.filter {
            $0.quality == .valid && HealthSampleValidation.rejectionReason($0, now: now) == nil
        }
        let invalid = measurements.filter {
            $0.quality != .valid || HealthSampleValidation.rejectionReason($0, now: now) != nil
        }
        try await repository.markHealthMeasurements(invalid.map(\.id), status: .invalid,
                                                    error: "Rejected by final HealthKit validation")
        guard !sourceValid.isEmpty else { return 0 }
        guard measurements.count <= 10_000 else {
            try await repository.markHealthMeasurements(sourceValid.map(\.id), status: .suppressedByRateLimit,
                                                        error: "Circuit breaker: pathological submission")
            throw CircuitBreakerError(reason: "\(measurements.count) objects submitted in one operation")
        }
        var valid: [HealthMeasurement] = []
        for (context, rows) in Dictionary(grouping: sourceValid, by: \.rateContext) {
            valid += try await applyProjection(HealthKitMetricRegistry.projection(
                for: definition.metric, context: context), to: rows, repository: repository)
        }
        valid.sort { ($0.startTs, $0.id) < ($1.startTs, $1.id) }
        guard !valid.isEmpty else { return 0 }

        switch definition.kind {
        case .quantity:
            return try await writeQuantities(valid, definition: definition, device: device, repository: repository)
        case .category:
            return try await writeCategories(valid, definition: definition, device: device, repository: repository)
        case .workout:
            return try await writeWorkoutMeasurements(valid, device: device, repository: repository)
        case .unsupported:
            try await repository.markHealthMeasurements(valid.map(\.id), status: .unsupported)
            return 0
        }
    }

    func deleteOwned(_ rows: [HealthMeasurement], definition: HealthKitMetricDefinition,
                     repository: WhoopStore) async throws -> Int {
        guard !rows.isEmpty, let identifier = definition.identifier else { return 0 }
        let type: HKSampleType?
        switch definition.kind {
        case .quantity: type = HKObjectType.quantityType(forIdentifier: .init(rawValue: identifier))
        case .category: type = HKObjectType.categoryType(forIdentifier: .init(rawValue: identifier))
        case .workout: type = HKObjectType.workoutType()
        case .unsupported: type = nil
        }
        guard let type else { return 0 }
        try await repository.markHealthMeasurements(rows.map(\.id), status: .deleting)
        do {
            try await client.deleteOwnedObjects(syncIdentifiers: Set(rows.map(\.id)), type: type)
            try await repository.markHealthMeasurements(rows.map(\.id), status: .deleted,
                                                        writtenAt: Date().timeIntervalSince1970)
            try await repository.removeHealthKitOwnership(rows.map(\.id))
            return rows.count
        } catch {
            try? await repository.markHealthMeasurements(rows.map(\.id), status: .pendingDeletion,
                                                         error: "owned-delete:\(error.localizedDescription)")
            throw error
        }
    }

    /// Final safety boundary. Selection is deterministic and only chooses real source records.
    /// Once a bucket has a selected/written record, late or replayed records in that bucket are suppressed.
    private func applyProjection(_ policy: HealthKitProjectionPolicy, to rows: [HealthMeasurement],
                                 repository: WhoopStore) async throws -> [HealthMeasurement] {
        guard let first = rows.first else { return [] }
        if policy.mode == .doNotWrite {
            try await repository.markHealthMeasurements(rows.map(\.id), status: .suppressedByProjectionPolicy)
            return []
        }
        var occupied = Set<Int64>()
        if policy.mode == .downsample, let interval = policy.minimumInterval, interval > 0 {
            for row in rows {
                let bucket = Int64(floor(row.startTs / interval))
                if occupied.contains(bucket) { continue }
                let start = Double(bucket) * interval
                let count = try await repository.healthMeasurementCount(
                    metric: row.metric, deviceId: row.deviceId, statuses: [.writing, .written],
                    from: start, to: start + interval)
                if count > 0 { occupied.insert(bucket) }
            }
        }
        let projection = HealthProjectionSelector.select(rows, policy: policy, occupiedBuckets: occupied)
        if let reason = HealthExportSafetyPolicy.breakerReason(for: .init(
            metric: first.metric, pending: rows.count, source: rows.count,
            selected: projection.selected.count, retries: 0, outputLastHour: 0,
            outputLastDay: 0, previousHourOutput: 0)) {
            throw CircuitBreakerError(reason: reason)
        }
        try await repository.markHealthMeasurements(projection.suppressed.map(\.id),
                                                    status: .suppressedByProjectionPolicy)
        var selected = projection.selected
        let writtenStates: [HealthKitWriteStatus] = [.writing, .written]
        var accepted: [HealthMeasurement] = []
        var rejected: [HealthMeasurement] = []
        var dayUsed: [Int64: Int] = [:], hourUsed: [Int64: Int] = [:]
        for row in selected {
            let dayBucket = Int64(floor(row.startTs / 86_400))
            let hourBucket = Int64(floor(row.startTs / 3_600))
            if dayUsed[dayBucket] == nil {
                dayUsed[dayBucket] = try await repository.healthMeasurementCount(
                    metric: row.metric, deviceId: row.deviceId, statuses: writtenStates,
                    from: Double(dayBucket) * 86_400, to: Double(dayBucket + 1) * 86_400)
            }
            if hourUsed[hourBucket] == nil {
                hourUsed[hourBucket] = try await repository.healthMeasurementCount(
                    metric: row.metric, deviceId: row.deviceId, statuses: writtenStates,
                    from: Double(hourBucket) * 3_600, to: Double(hourBucket + 1) * 3_600)
            }
            let dayOK = dayUsed[dayBucket, default: 0] < (policy.maxSamplesPerDay ?? .max)
            let hourOK = hourUsed[hourBucket, default: 0] < (policy.maxSamplesPerHour ?? .max)
            if dayOK && hourOK {
                accepted.append(row); dayUsed[dayBucket, default: 0] += 1; hourUsed[hourBucket, default: 0] += 1
            } else { rejected.append(row) }
        }
        try await repository.markHealthMeasurements(rejected.map(\.id), status: .suppressedByRateLimit,
                                                    error: "Metric-specific HealthKit timestamp-bucket limit")
#if DEBUG
        print("[HealthKit] metric=\(first.metric.rawValue) sourceSamples=\(rows.count) selectedSamples=\(accepted.count) suppressed=\(rows.count - accepted.count)")
#endif
        return accepted
    }

    private func writeQuantities(_ rows: [HealthMeasurement], definition: HealthKitMetricDefinition,
                                 device: HKDevice?, repository: WhoopStore) async throws -> Int {
        guard let identifier = definition.identifier,
              let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: identifier)),
              let unit = definition.unit else {
            try await repository.markHealthMeasurements(rows.map(\.id), status: .unsupported); return 0
        }
        guard store.authorizationStatus(for: type) == .sharingAuthorized else {
            try await repository.markHealthMeasurements(rows.map(\.id), status: .unauthorized); return 0
        }
        let eligible = rows.filter { $0.value?.isFinite == true }
        let malformed = rows.filter { $0.value?.isFinite != true }
        try await repository.markHealthMeasurements(malformed.map(\.id), status: .invalid,
                                                    error: "Quantity has no finite value")
        let samples = eligible.compactMap { row -> HKQuantitySample? in
            guard let value = row.value else { return nil }
            return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
                start: Date(timeIntervalSince1970: row.startTs), end: Date(timeIntervalSince1970: row.endTs),
                device: device, metadata: metadata(for: row))
        }
        try await persist(samples, rows: eligible, repository: repository)
        return samples.count
    }

    private func writeCategories(_ rows: [HealthMeasurement], definition: HealthKitMetricDefinition,
                                 device: HKDevice?, repository: WhoopStore) async throws -> Int {
        guard let identifier = definition.identifier,
              let type = HKObjectType.categoryType(forIdentifier: .init(rawValue: identifier)) else {
            try await repository.markHealthMeasurements(rows.map(\.id), status: .unsupported); return 0
        }
        guard store.authorizationStatus(for: type) == .sharingAuthorized else {
            try await repository.markHealthMeasurements(rows.map(\.id), status: .unauthorized); return 0
        }
        var accepted: [HealthMeasurement] = []
        var samples: [HKCategorySample] = []
        for row in rows {
            guard row.endTs > row.startTs, let raw = row.categoryValue,
                  let stage = HealthSleepStage(rawValue: raw), let value = sleepValue(stage) else { continue }
            accepted.append(row)
            samples.append(HKCategorySample(type: type, value: value.rawValue,
                start: Date(timeIntervalSince1970: row.startTs), end: Date(timeIntervalSince1970: row.endTs),
                device: device, metadata: metadata(for: row)))
        }
        let rejected = rows.filter { row in !accepted.contains(where: { $0.id == row.id }) }
        try await repository.markHealthMeasurements(rejected.map(\.id), status: .invalid,
                                                    error: "Invalid sleep interval or stage")
        try await persist(samples, rows: accepted, repository: repository)
        return samples.count
    }

    private func writeWorkoutMeasurements(_ rows: [HealthMeasurement], device: HKDevice?,
                                          repository: WhoopStore) async throws -> Int {
        let type = HKObjectType.workoutType()
        guard store.authorizationStatus(for: type) == .sharingAuthorized else {
            try await repository.markHealthMeasurements(rows.map(\.id), status: .unauthorized); return 0
        }
        var written = 0
        for row in rows {
            guard row.endTs > row.startTs,
                  let data = row.metadataJSON.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(HealthWorkoutPayload.self, from: data) else {
                try await repository.markHealthMeasurements([row.id], status: .invalid,
                                                            error: "Invalid workout payload"); continue
            }
            try await repository.markHealthMeasurements([row.id], status: .writing)
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = Self.activityType(for: payload.sport)
            let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: device)
            do {
                let start = Date(timeIntervalSince1970: row.startTs)
                let end = Date(timeIntervalSince1970: row.endTs)
                try await builder.beginCollection(at: start)
                try await builder.addMetadata(metadata(for: row))
                var extras: [HKSample] = []
                if let kcal = payload.energyKcal, kcal > 0,
                   let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
                   store.authorizationStatus(for: energy) == .sharingAuthorized {
                    extras.append(HKQuantitySample(type: energy, quantity: .init(unit: .kilocalorie(), doubleValue: kcal),
                                                   start: start, end: end, device: device, metadata: metadata(for: row, suffix: "energy")))
                }
                if let meters = payload.distanceM, meters > 0, let distanceId = Self.distanceType(for: payload.sport),
                   let distance = HKQuantityType.quantityType(forIdentifier: distanceId),
                   store.authorizationStatus(for: distance) == .sharingAuthorized {
                    extras.append(HKQuantitySample(type: distance, quantity: .init(unit: .meter(), doubleValue: meters),
                                                   start: start, end: end, device: device, metadata: metadata(for: row, suffix: "distance")))
                }
                if !extras.isEmpty { try await builder.addSamples(extras) }
                try await builder.endCollection(at: end)
                let workout = try await builder.finishWorkout()
                try await repository.markHealthMeasurements([row.id], status: .written,
                    writtenAt: Date().timeIntervalSince1970, healthKitUUID: workout?.uuid.uuidString)
                if let workout {
                    try await repository.replaceHealthKitOwnership([.init(
                        syncIdentifier: row.id, healthKitUUID: workout.uuid.uuidString,
                        sampleType: HKWorkoutType.workoutType().identifier,
                        startTs: row.startTs, endTs: row.endTs)])
                }
                written += 1 + extras.count
            } catch {
                builder.discardWorkout()
                try? await markFailure(error, rows: [row], repository: repository)
                throw error
            }
        }
        return written
    }

    private func persist(_ samples: [HKSample], rows: [HealthMeasurement], repository: WhoopStore) async throws {
        guard !samples.isEmpty else { return }
        let pairs = Array(zip(rows, samples))
        try await HealthBatchCommitPlanner.execute(pairs, size: 25, save: { chunk in
            let rowChunk = chunk.map(\.0), sampleChunk = chunk.map(\.1)
            try await repository.markHealthMeasurements(rowChunk.map(\.id), status: .writing)
            do { try await self.save(sampleChunk) }
            catch {
                try? await self.markFailure(error, rows: rowChunk, repository: repository)
                throw error
            }
        }, commit: { chunk in
                let rowChunk = chunk.map(\.0), sampleChunk = chunk.map(\.1)
                let now = Date().timeIntervalSince1970
                for (row, sample) in zip(rowChunk, sampleChunk) {
                    try await repository.markHealthMeasurements([row.id], status: .written,
                                                                writtenAt: now, healthKitUUID: sample.uuid.uuidString)
                }
                try await repository.replaceHealthKitOwnership(zip(rowChunk, sampleChunk).map { row, sample in
                    HealthKitOwnedObject(syncIdentifier: row.id, healthKitUUID: sample.uuid.uuidString,
                                         sampleType: sample.sampleType.identifier,
                                         startTs: row.startTs, endTs: row.endTs, lastSeenAt: now)
                })
        })
    }

    private func markFailure(_ error: Error, rows: [HealthMeasurement], repository: WhoopStore) async throws {
        let classification = classify(error)
        let status: HealthKitWriteStatus
        if classification.hasPrefix("authorization:") { status = .unauthorized }
        else if classification.hasPrefix("invalid-sample:") { status = .invalid }
        else { status = .failed }
        try await repository.markHealthMeasurements(rows.map(\.id), status: status, error: classification)
    }

    private func metadata(for row: HealthMeasurement, suffix: String? = nil) -> [String: Any] {
        let id = suffix.map { "\(row.id):\($0)" } ?? row.id
        return [HKMetadataKeySyncIdentifier: id,
                HKMetadataKeySyncVersion: row.healthKitSyncVersion,
                HKMetadataKeyExternalUUID: id,
                "NOOPOrigin": row.source.rawValue,
                "NOOPDeviceID": row.deviceId,
                "NOOPSourceIdentifier": row.sourceIdentifier,
                "NOOPRateContext": row.rateContext.rawValue]
    }

    private func sleepValue(_ stage: HealthSleepStage) -> HKCategoryValueSleepAnalysis? {
        switch stage {
        case .inBed: return .inBed
        case .awake: return .awake
        case .core: return .asleepCore
        case .deep: return .asleepDeep
        case .rem: return .asleepREM
        case .unspecified: return .asleepUnspecified
        }
    }

    private func classify(_ error: Error) -> String {
        if error is SaveTimeout { return "temporary:timeout:\(error.localizedDescription)" }
        let ns = error as NSError
        if ns.domain == HKErrorDomain {
            switch HKError.Code(rawValue: ns.code) {
            case .errorAuthorizationDenied: return "authorization:\(error.localizedDescription)"
            case .errorHealthDataUnavailable: return "temporary:health-data-unavailable:\(error.localizedDescription)"
            case .errorInvalidArgument: return "invalid-sample:\(error.localizedDescription)"
            default: return "healthkit:\(error.localizedDescription)"
            }
        }
        return "store:\(error.localizedDescription)"
    }

    private func save(_ samples: [HKSample]) async throws {
        guard !samples.isEmpty else { return }
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            var finished = false
            func finish(_ result: Result<Void, Error>) {
                guard !finished else { return }; finished = true; continuation.resume(returning: result)
            }
            Task { @MainActor in
                do { try await client.save(samples); finish(.success(())) }
                catch { finish(.failure(error)) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                finish(.failure(SaveTimeout(sampleCount: samples.count)))
            }
        }
        try result.get()
    }

    private static func activityType(for sport: String) -> HKWorkoutActivityType {
        switch sport.lowercased() {
        case "running": return .running; case "walking": return .walking; case "hiking": return .hiking
        case "cycling": return .cycling; case "hiit": return .highIntensityIntervalTraining
        case "strength", "strength training", "strength trainer", "weightlifting": return .traditionalStrengthTraining
        case "yoga": return .yoga; case "pilates": return .pilates; case "rowing": return .rowing
        case "swimming": return .swimming; case "boxing": return .boxing; case "tennis": return .tennis
        case "soccer": return .soccer; default: return .other
        }
    }

    private static func distanceType(for sport: String) -> HKQuantityTypeIdentifier? {
        switch sport.lowercased() {
        case "running", "walking", "hiking": return .distanceWalkingRunning
        case "cycling": return .distanceCycling
        default: return nil
        }
    }
}
#endif
