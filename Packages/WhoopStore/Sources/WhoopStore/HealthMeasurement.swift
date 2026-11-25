import Foundation
import GRDB

public enum HealthMetric: String, Codable, CaseIterable, Sendable {
    case heartRate, heartRateVariabilitySDNN, respiratoryRate, oxygenSaturation
    case activeEnergy, basalEnergy, stepCount, walkingRunningDistance, cyclingDistance
    case sleepStage, restingHeartRate, vo2Max, workout
}

public enum HealthUnit: String, Codable, Sendable {
    case countPerMinute, millisecond, breathsPerMinute, fraction, kilocalorie, meter, count
}

public enum MeasurementSource: String, Codable, Sendable {
    case measuredDevice, derivedByNoop, estimatedByNoop, userEntered
}

public enum MeasurementQuality: String, Codable, Sendable {
    case valid, uncertain, rejected
}

public enum HealthKitWriteStatus: String, Codable, Sendable {
    case pending, writing, written, failed, invalid, unsupported, unauthorized
    case pendingDeletion, deleting, deleted
    case suppressedByProjectionPolicy, suppressedByRateLimit, expiredByExportBoundary
}

public enum HealthRateContext: String, Codable, CaseIterable, Sendable {
    case background, sleep, workout, manual, historicalBackfill
}

public enum HealthProjectionMode: String, Codable, Sendable {
    case preserve, downsample, aggregate, interval, eventOnly, doNotWrite
}

public struct HealthKitProjectionPolicy: Codable, Sendable, Equatable {
    public let mode: HealthProjectionMode
    public let minimumInterval: Double?
    public let maxSamplesPerHour: Int?
    public let maxSamplesPerDay: Int?
    public let allowLiveHighFrequency: Bool
    public init(mode: HealthProjectionMode, minimumInterval: Double? = nil,
                maxSamplesPerHour: Int? = nil, maxSamplesPerDay: Int? = nil,
                allowLiveHighFrequency: Bool = false) {
        self.mode = mode; self.minimumInterval = minimumInterval
        self.maxSamplesPerHour = maxSamplesPerHour; self.maxSamplesPerDay = maxSamplesPerDay
        self.allowLiveHighFrequency = allowLiveHighFrequency
    }
}

public enum HealthSleepStage: Int, Codable, Sendable {
    case inBed = 0, awake = 1, core = 2, deep = 3, rem = 4, unspecified = 5
}

public struct HealthWorkoutPayload: Codable, Sendable, Equatable {
    public let sport: String
    public let energyKcal: Double?
    public let distanceM: Double?
    public init(sport: String, energyKcal: Double?, distanceM: Double?) {
        self.sport = sport; self.energyKcal = energyKcal; self.distanceM = distanceM
    }
}

public enum DeviceCapability: String, Codable, Sendable, Hashable {
    case heartRate, rrIntervals, oxygenSaturation, skinTemperature, steps, sleep, workouts
}

public struct HealthDevice: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let manufacturer: String?
    public let model: String?
    public let hardwareVersion: String?
    public let firmwareVersion: String?
    public let capabilities: Set<DeviceCapability>
    public init(id: String, name: String, manufacturer: String?, model: String?,
                hardwareVersion: String? = nil, firmwareVersion: String? = nil,
                capabilities: Set<DeviceCapability>) {
        self.id = id; self.name = name; self.manufacturer = manufacturer; self.model = model
        self.hardwareVersion = hardwareVersion; self.firmwareVersion = firmwareVersion
        self.capabilities = capabilities
    }
}

/// Manufacturer-independent health datum. Device/protocol code persists this model; analytics and
/// HealthKit consume it without needing BLE UUIDs, packet layouts or HKObject subclasses.
public struct HealthMeasurement: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "healthMeasurement"
    public var id: String
    public var metric: HealthMetric
    public var startTs: Double
    public var endTs: Double
    public var value: Double?
    public var unit: HealthUnit?
    public var categoryValue: Int?
    public var deviceId: String
    public var source: MeasurementSource
    public var quality: MeasurementQuality
    public var sourceSequence: Int64?
    public var sourceIdentifier: String
    public var clockEpoch: String?
    public var rateContext: HealthRateContext
    public var metadataJSON: String
    public var receivedAt: Double?
    public var processedAt: Double
    public var healthKitUUID: String?
    public var healthKitStatus: HealthKitWriteStatus
    public var healthKitAttempts: Int
    public var healthKitSyncVersion: Int
    public var healthKitLastError: String?
    public var healthKitWrittenAt: Double?

    public init(id: String, metric: HealthMetric, startTs: Double, endTs: Double,
                value: Double?, unit: HealthUnit?, categoryValue: Int? = nil,
                deviceId: String, source: MeasurementSource, quality: MeasurementQuality,
                sourceSequence: Int64? = nil, sourceIdentifier: String = "noop",
                clockEpoch: String? = nil, rateContext: HealthRateContext = .background,
                metadataJSON: String = "{}",
                receivedAt: Double? = nil, processedAt: Double = Date().timeIntervalSince1970,
                healthKitUUID: String? = nil, healthKitStatus: HealthKitWriteStatus = .pending,
                healthKitAttempts: Int = 0, healthKitSyncVersion: Int = 1,
                healthKitLastError: String? = nil,
                healthKitWrittenAt: Double? = nil) {
        self.id = id; self.metric = metric; self.startTs = startTs; self.endTs = endTs
        self.value = value; self.unit = unit; self.categoryValue = categoryValue
        self.deviceId = deviceId; self.source = source; self.quality = quality
        self.sourceSequence = sourceSequence; self.sourceIdentifier = sourceIdentifier
        self.clockEpoch = clockEpoch; self.rateContext = rateContext; self.metadataJSON = metadataJSON
        self.receivedAt = receivedAt; self.processedAt = processedAt
        self.healthKitUUID = healthKitUUID; self.healthKitStatus = healthKitStatus
        self.healthKitAttempts = healthKitAttempts; self.healthKitSyncVersion = healthKitSyncVersion
        self.healthKitLastError = healthKitLastError
        self.healthKitWrittenAt = healthKitWrittenAt
    }
}

public struct HealthKitOwnedObject: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "healthKitOwnedObject"
    public var syncIdentifier: String
    public var healthKitUUID: String
    public var sampleType: String
    public var startTs: Double
    public var endTs: Double
    public var lastSeenAt: Double
    public init(syncIdentifier: String, healthKitUUID: String, sampleType: String,
                startTs: Double, endTs: Double, lastSeenAt: Double = Date().timeIntervalSince1970) {
        self.syncIdentifier = syncIdentifier; self.healthKitUUID = healthKitUUID
        self.sampleType = sampleType; self.startTs = startTs; self.endTs = endTs; self.lastSeenAt = lastSeenAt
    }
}

extension WhoopStore {
    private struct ProjectionBucket: Hashable {
        let metric: HealthMetric
        let deviceId: String
        let context: HealthRateContext
        let interval: Double
        let index: Int64
    }

    public func healthKitStatusCounts(deviceId: String) async throws -> [HealthKitWriteStatus: Int] {
        try syncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT healthKitStatus, COUNT(*) AS count
                FROM healthMeasurement WHERE deviceId = ? GROUP BY healthKitStatus
                """, arguments: [deviceId])
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let raw: String = row["healthKitStatus"],
                      let status = HealthKitWriteStatus(rawValue: raw) else { return nil }
                let count: Int = row["count"]
                return (status, count)
            })
        }
    }

    public func upsertHealthMeasurements(_ rows: [HealthMeasurement]) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            for row in rows {
                if let old = try HealthMeasurement.fetchOne(db, key: row.id) {
                    var canonical = row
                    if old.metric == .sleepStage && old.metadataJSON.contains("oneShotSleepRecovery") {
                        canonical.metadataJSON = old.metadataJSON
                    }
                    let changed = old.metric != canonical.metric || old.startTs != canonical.startTs ||
                        old.endTs != canonical.endTs || old.value != canonical.value || old.unit != canonical.unit ||
                        old.categoryValue != canonical.categoryValue || old.metadataJSON != canonical.metadataJSON ||
                        old.sourceIdentifier != canonical.sourceIdentifier || old.clockEpoch != canonical.clockEpoch ||
                        old.rateContext != canonical.rateContext || old.quality != canonical.quality
                    guard changed else { continue }
                    var replacement = canonical
                    replacement.healthKitSyncVersion = old.healthKitSyncVersion + 1
                    replacement.healthKitStatus = old.healthKitStatus == .expiredByExportBoundary
                        ? .expiredByExportBoundary : .pending
                    replacement.healthKitAttempts = 0
                    replacement.healthKitUUID = old.healthKitUUID
                    try replacement.update(db)
                } else {
                    var inserted = row
                    if let owned = try HealthKitOwnedObject.fetchOne(db, key: row.id) {
                        inserted.healthKitStatus = .written
                        inserted.healthKitUUID = owned.healthKitUUID
                        inserted.healthKitWrittenAt = owned.lastSeenAt
                    }
                    try inserted.insert(db)
                }
            }
        }
    }

    /// Atomically materializes high-rate source rows into the HealthKit-facing canonical queue and
    /// classifies every non-selected row before another task can observe it as exportable. Raw HR
    /// remains in `hrSample`; these rows are queue/projection records, not the analytics source.
    public func upsertProjectedHealthMeasurements(_ rows: [HealthMeasurement]) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            var buckets = Set<ProjectionBucket>()
            func addBucket(for row: HealthMeasurement) {
                let policy = HealthProjectionPolicies.policy(for: row.metric, context: row.rateContext)
                guard policy.mode == .downsample, let interval = policy.minimumInterval, interval > 0 else { return }
                buckets.insert(.init(metric: row.metric, deviceId: row.deviceId,
                                     context: row.rateContext, interval: interval,
                                     index: Int64(floor(row.startTs / interval))))
            }
            for row in rows {
                if let old = try HealthMeasurement.fetchOne(db, key: row.id) {
                    addBucket(for: old)
                    let changed = old.metric != row.metric || old.startTs != row.startTs ||
                        old.endTs != row.endTs || old.value != row.value || old.unit != row.unit ||
                        old.categoryValue != row.categoryValue || old.metadataJSON != row.metadataJSON ||
                        old.sourceIdentifier != row.sourceIdentifier || old.clockEpoch != row.clockEpoch ||
                        old.rateContext != row.rateContext || old.quality != row.quality
                    if changed {
                        var replacement = row
                        replacement.healthKitSyncVersion = old.healthKitSyncVersion + 1
                        replacement.healthKitStatus = old.healthKitStatus == .expiredByExportBoundary
                            ? .expiredByExportBoundary : .pending
                        replacement.healthKitAttempts = 0
                        replacement.healthKitUUID = old.healthKitUUID
                        try replacement.update(db)
                    }
                } else {
                    var inserted = row
                    if let owned = try HealthKitOwnedObject.fetchOne(db, key: row.id) {
                        inserted.healthKitStatus = .written
                        inserted.healthKitUUID = owned.healthKitUUID
                        inserted.healthKitWrittenAt = owned.lastSeenAt
                    }
                    try inserted.insert(db)
                }
                addBucket(for: row)
            }
            for bucket in buckets {
                _ = try Self.reproject(bucket: bucket, db: db)
            }
        }
    }

    /// Reclassifies an existing canonical queue without deleting raw measurements or touching
    /// HealthKit. Used by migrations/controlled maintenance when projection moves ahead of writing.
    @discardableResult
    public func reprojectHealthMeasurements(metric: HealthMetric, deviceId: String,
                                             notBefore: Double? = nil,
                                             policy override: HealthKitProjectionPolicy? = nil) async throws -> Int {
        try syncWrite { db in
            var sql = "SELECT * FROM healthMeasurement WHERE metric = ? AND deviceId = ?"
            var arguments: StatementArguments = [metric.rawValue, deviceId]
            if let notBefore {
                sql += " AND startTs >= ?"
                arguments += [notBefore]
            }
            let rows = try HealthMeasurement.fetchAll(db, sql: sql, arguments: arguments)
            var buckets = Set<ProjectionBucket>()
            for row in rows {
                let policy = override ?? HealthProjectionPolicies.policy(for: metric, context: row.rateContext)
                guard policy.mode == .downsample, let interval = policy.minimumInterval, interval > 0 else { continue }
                buckets.insert(.init(metric: metric, deviceId: deviceId, context: row.rateContext,
                                     interval: interval, index: Int64(floor(row.startTs / interval))))
            }
            var changed = 0
            for bucket in buckets { changed += try Self.reproject(bucket: bucket, db: db) }
            return changed
        }
    }

    private static func reproject(bucket: ProjectionBucket, db: Database) throws -> Int {
        let from = Double(bucket.index) * bucket.interval
        let to = from + bucket.interval
        let rows = try HealthMeasurement.fetchAll(db, sql: """
            SELECT * FROM healthMeasurement
            WHERE metric = ? AND deviceId = ? AND rateContext = ? AND startTs >= ? AND startTs < ?
            ORDER BY startTs, id
            """, arguments: [bucket.metric.rawValue, bucket.deviceId, bucket.context.rawValue, from, to])
        let occupied = rows.contains { $0.healthKitStatus == .writing || $0.healthKitStatus == .written }
        let mutableStatuses: Set<HealthKitWriteStatus> = [.pending, .failed, .unauthorized,
                                                          .suppressedByProjectionPolicy]
        let candidates = rows.filter { $0.quality == .valid && mutableStatuses.contains($0.healthKitStatus) }
        let selectedID = occupied ? nil : candidates.first?.id
        var changed = 0
        for row in candidates {
            let desired: HealthKitWriteStatus
            if row.id == selectedID {
                // Preserve a real failure/authorization state. A replay must not silently reset retry state.
                desired = row.healthKitStatus == .suppressedByProjectionPolicy ? .pending : row.healthKitStatus
            } else {
                desired = .suppressedByProjectionPolicy
            }
            guard desired != row.healthKitStatus else { continue }
            try db.execute(sql: """
                UPDATE healthMeasurement SET healthKitStatus = ?, healthKitLastError = NULL WHERE id = ?
                """, arguments: [desired.rawValue, row.id])
            changed += db.changesCount
        }
        return changed
    }

    public func replaceHealthKitOwnership(_ objects: [HealthKitOwnedObject]) async throws {
        try syncWrite { db in
            for object in objects { try object.save(db) }
        }
    }

    public func pendingHealthKitDeletions(metric: HealthMetric, deviceId: String,
                                          limit: Int, notBefore: Double? = nil) async throws -> [HealthMeasurement] {
        try syncRead { db in
            var request = HealthMeasurement
                .filter(Column("metric") == metric.rawValue && Column("deviceId") == deviceId &&
                        [HealthKitWriteStatus.pendingDeletion.rawValue, HealthKitWriteStatus.deleting.rawValue]
                            .contains(Column("healthKitStatus")))
            if let notBefore { request = request.filter(Column("startTs") >= notBefore) }
            return try request.order(Column("startTs"), Column("id")).limit(limit).fetchAll(db)
        }
    }

    /// Advances the local export boundary without deleting source data or touching HealthKit.
    @discardableResult
    public func expireHealthMeasurements(deviceId: String, before boundary: Double) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE healthMeasurement
                SET healthKitStatus = ?, healthKitLastError = 'Before persistent export boundary'
                WHERE deviceId = ? AND startTs < ? AND healthKitStatus IN (?, ?, ?, ?)
                """, arguments: [HealthKitWriteStatus.expiredByExportBoundary.rawValue,
                                  deviceId, boundary,
                                  HealthKitWriteStatus.pending.rawValue,
                                  HealthKitWriteStatus.failed.rawValue,
                                  HealthKitWriteStatus.unauthorized.rawValue,
                                  HealthKitWriteStatus.writing.rawValue])
            return db.changesCount
        }
    }

    /// Expires a stale export queue for one metric while preserving the local high-resolution
    /// source rows and every other HealthKit stream. This is used by the future-continuity path:
    /// an interrupted HR queue must never be replayed for days before fresh HR can be written.
    @discardableResult
    public func expireHealthMeasurements(metric: HealthMetric, deviceId: String,
                                         before boundary: Double) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE healthMeasurement
                SET healthKitStatus = ?, healthKitLastError = 'Expired from stale export queue'
                WHERE metric = ? AND deviceId = ? AND startTs < ?
                  AND healthKitStatus IN (?, ?, ?, ?)
                """, arguments: [HealthKitWriteStatus.expiredByExportBoundary.rawValue,
                                  metric.rawValue, deviceId, boundary,
                                  HealthKitWriteStatus.pending.rawValue,
                                  HealthKitWriteStatus.failed.rawValue,
                                  HealthKitWriteStatus.unauthorized.rawValue,
                                  HealthKitWriteStatus.writing.rawValue])
            return db.changesCount
        }
    }

    /// Opens one narrowly bounded exception through an already-consumed recovery floor. Every id
    /// must name a valid sleep interval wholly contained in the approved night; otherwise nothing
    /// is changed. No generic historical status can be revived through this API.
    @discardableResult
    public func authorizeOneShotSleepRecovery(_ identifiers: Set<String>, deviceId: String,
                                              windowStart: Double, windowEnd: Double) async throws -> Int {
        guard !identifiers.isEmpty, windowEnd > windowStart else { return 0 }
        return try syncWrite { db in
            let rows = try HealthMeasurement.filter(identifiers.contains(Column("id"))).fetchAll(db)
            guard rows.count == identifiers.count,
                  rows.allSatisfy({ $0.metric == .sleepStage && $0.deviceId == deviceId &&
                      $0.startTs >= windowStart && $0.endTs <= windowEnd && $0.endTs > $0.startTs }) else {
                throw NSError(domain: "WhoopStore.OneShotSleepRecovery", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "one-shot sleep recovery scope validation failed"])
            }
            var changed = 0
            for row in rows where row.healthKitStatus != .written {
                try db.execute(sql: """
                    UPDATE healthMeasurement SET healthKitStatus = ?, healthKitLastError = NULL
                    WHERE id = ? AND healthKitStatus IN (?, ?, ?, ?, ?, ?)
                    """, arguments: [HealthKitWriteStatus.pending.rawValue, row.id,
                                      HealthKitWriteStatus.expiredByExportBoundary.rawValue,
                                      HealthKitWriteStatus.pending.rawValue,
                                      HealthKitWriteStatus.failed.rawValue,
                                      HealthKitWriteStatus.unauthorized.rawValue,
                                      HealthKitWriteStatus.deleted.rawValue,
                                      HealthKitWriteStatus.pendingDeletion.rawValue])
                changed += db.changesCount
            }
            return changed
        }
    }

    /// Marks previously exported objects absent from a complete source snapshot as tombstones.
    public func reconcileHealthMeasurementSnapshot(metric: HealthMetric, deviceId: String,
                                                    from: Double, to: Double,
                                                    currentIdentifiers: Set<String>) async throws -> Int {
        try syncWrite { db in
            let old = try HealthMeasurement
                .filter(Column("metric") == metric.rawValue && Column("deviceId") == deviceId &&
                        Column("startTs") >= from && Column("startTs") < to &&
                        Column("healthKitStatus") == HealthKitWriteStatus.written.rawValue)
                .fetchAll(db)
            var changed = 0
            for row in old where !currentIdentifiers.contains(row.id) &&
                !row.metadataJSON.contains("oneShotSleepRecovery") {
                try db.execute(sql: "UPDATE healthMeasurement SET healthKitStatus = ? WHERE id = ?",
                               arguments: [HealthKitWriteStatus.pendingDeletion.rawValue, row.id])
                changed += db.changesCount
            }
            return changed
        }
    }

    public func removeHealthKitOwnership(_ identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        try syncWrite { db in
            for id in identifiers {
                try db.execute(sql: "DELETE FROM healthKitOwnedObject WHERE syncIdentifier = ?", arguments: [id])
            }
        }
    }

    public func pendingHealthMeasurements(metric: HealthMetric, deviceId: String,
                                          limit: Int, notBefore: Double? = nil) async throws -> [HealthMeasurement] {
        try syncRead { db in
            var request = HealthMeasurement
                .filter(Column("metric") == metric.rawValue && Column("deviceId") == deviceId &&
                        [HealthKitWriteStatus.pending.rawValue, HealthKitWriteStatus.failed.rawValue]
                            .contains(Column("healthKitStatus")))
            if let notBefore { request = request.filter(Column("startTs") >= notBefore) }
            return try request.order(Column("startTs"), Column("id"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func healthMeasurement(id: String) async throws -> HealthMeasurement? {
        try syncRead { db in try HealthMeasurement.fetchOne(db, key: id) }
    }

    public func healthMeasurements(metric: HealthMetric, deviceId: String,
                                   statuses: [HealthKitWriteStatus], from: Double, to: Double,
                                   context: HealthRateContext? = nil,
                                   limit: Int = 10_000) async throws -> [HealthMeasurement] {
        try syncRead { db in
            var request = HealthMeasurement.filter(
                Column("metric") == metric.rawValue && Column("deviceId") == deviceId &&
                statuses.map(\.rawValue).contains(Column("healthKitStatus")) &&
                Column("startTs") >= from && Column("startTs") < to)
            if let context { request = request.filter(Column("rateContext") == context.rawValue) }
            return try request.order(Column("startTs"), Column("id")).limit(limit).fetchAll(db)
        }
    }

    public func healthKitOwnership(syncIdentifier: String) async throws -> HealthKitOwnedObject? {
        try syncRead { db in try HealthKitOwnedObject.fetchOne(db, key: syncIdentifier) }
    }

    public func healthMeasurementCount(deviceId: String, statuses: [HealthKitWriteStatus]) async throws -> Int {
        try syncRead { db in
            try HealthMeasurement
                .filter(Column("deviceId") == deviceId && statuses.map(\.rawValue).contains(Column("healthKitStatus")))
                .fetchCount(db)
        }
    }

    public func healthMeasurementCount(deviceId: String, statuses: [HealthKitWriteStatus],
                                       before: Double) async throws -> Int {
        try syncRead { db in
            try HealthMeasurement
                .filter(Column("deviceId") == deviceId &&
                        statuses.map(\.rawValue).contains(Column("healthKitStatus")) &&
                        Column("startTs") < before)
                .fetchCount(db)
        }
    }

    public func healthExportLoad(metric: HealthMetric, deviceId: String,
                                 now: Double = Date().timeIntervalSince1970,
                                 notBefore: Double? = nil) async throws -> HealthExportLoad {
        try syncRead { db in
            let boundaryClause = notBefore == nil ? "" : " AND startTs >= ?"
            var pendingArguments: StatementArguments = [deviceId, metric.rawValue,
                                                         HealthKitWriteStatus.pending.rawValue,
                                                         HealthKitWriteStatus.failed.rawValue]
            if let notBefore { pendingArguments += [notBefore] }
            let pending = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM healthMeasurement WHERE deviceId = ? AND metric = ?
                AND healthKitStatus IN (?, ?)\(boundaryClause)
                """, arguments: pendingArguments) ?? 0
            var retryArguments: StatementArguments = [deviceId, metric.rawValue]
            if let notBefore { retryArguments += [notBefore] }
            let retries = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(healthKitAttempts), 0) FROM healthMeasurement
                WHERE deviceId = ? AND metric = ?\(boundaryClause)
                """, arguments: retryArguments) ?? 0
            func output(_ from: Double, _ to: Double) throws -> Int {
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM healthMeasurement WHERE deviceId = ? AND metric = ?
                    AND healthKitStatus = ? AND healthKitWrittenAt >= ? AND healthKitWrittenAt < ?
                    """, arguments: [deviceId, metric.rawValue, HealthKitWriteStatus.written.rawValue, from, to]) ?? 0
            }
            return HealthExportLoad(metric: metric, pending: pending, source: 0, selected: 0,
                                    retries: retries, outputLastHour: try output(now - 3_600, now),
                                    outputLastDay: try output(now - 86_400, now),
                                    previousHourOutput: try output(now - 7_200, now - 3_600))
        }
    }

    public func requeueUnauthorizedHealthKitWrites(deviceId: String, notBefore: Double) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE healthMeasurement SET healthKitStatus = ?, healthKitLastError = NULL
                WHERE deviceId = ? AND healthKitStatus = ? AND startTs >= ?
                """, arguments: [HealthKitWriteStatus.pending.rawValue, deviceId,
                                  HealthKitWriteStatus.unauthorized.rawValue, notBefore])
        }
    }

    public func reconcileHealthKitOwnedIdentifiers(_ identifiers: Set<String>, deviceId: String) async throws -> Int {
        guard !identifiers.isEmpty else { return 0 }
        return try syncWrite { db in
            var changed = 0
            for id in identifiers {
                try db.execute(sql: """
                    UPDATE healthMeasurement SET healthKitStatus = ?, healthKitLastError = NULL
                    WHERE id = ? AND deviceId = ? AND healthKitStatus IN (?, ?, ?)
                    """, arguments: [HealthKitWriteStatus.written.rawValue, id, deviceId,
                                      HealthKitWriteStatus.pending.rawValue,
                                      HealthKitWriteStatus.failed.rawValue,
                                      HealthKitWriteStatus.unauthorized.rawValue])
                changed += db.changesCount
            }
            return changed
        }
    }

    public func pruneHealthExportState(deviceId: String, olderThan cutoff: Double) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM healthMeasurement
                WHERE deviceId = ? AND startTs < ? AND healthKitStatus IN (?, ?, ?, ?, ?, ?)
                """, arguments: [deviceId, cutoff,
                                  HealthKitWriteStatus.written.rawValue,
                                  HealthKitWriteStatus.deleted.rawValue,
                                  HealthKitWriteStatus.invalid.rawValue,
                                  HealthKitWriteStatus.unsupported.rawValue,
                                  HealthKitWriteStatus.suppressedByProjectionPolicy.rawValue,
                                  HealthKitWriteStatus.suppressedByRateLimit.rawValue])
            return db.changesCount
        }
    }

    public func healthMeasurementCount(metric: HealthMetric, deviceId: String,
                                       statuses: [HealthKitWriteStatus], from: Double, to: Double) async throws -> Int {
        try syncRead { db in
            try HealthMeasurement
                .filter(Column("metric") == metric.rawValue && Column("deviceId") == deviceId &&
                        statuses.map(\.rawValue).contains(Column("healthKitStatus")) &&
                        Column("startTs") >= from && Column("startTs") < to)
                .fetchCount(db)
        }
    }

    public func markHealthMeasurements(_ ids: [String], status: HealthKitWriteStatus,
                                       error: String? = nil, writtenAt: Double? = nil,
                                       healthKitUUID: String? = nil) async throws {
        guard !ids.isEmpty else { return }
        try syncWrite { db in
            for id in ids {
                try db.execute(sql: """
                    UPDATE healthMeasurement
                    SET healthKitStatus = ?, healthKitAttempts = healthKitAttempts + CASE WHEN ? = ? THEN 1 ELSE 0 END,
                        healthKitLastError = ?, healthKitWrittenAt = COALESCE(?, healthKitWrittenAt),
                        healthKitUUID = COALESCE(?, healthKitUUID)
                    WHERE id = ?
                    """, arguments: [status.rawValue, status.rawValue, HealthKitWriteStatus.writing.rawValue,
                                      error, writtenAt, healthKitUUID, id])
            }
        }
    }

    /// A process can be suspended after setting `writing` and before receiving HealthKit's callback.
    /// Stable sync identifiers make retry safe; leaving these rows stuck would lose the export forever.
    public func requeueInterruptedHealthKitWrites(deviceId: String) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE healthMeasurement
                SET healthKitStatus = ?, healthKitLastError = ?
                WHERE deviceId = ? AND healthKitStatus = ?
                """, arguments: [HealthKitWriteStatus.pending.rawValue,
                                  "Interrupted before HealthKit acknowledgement", deviceId,
                                  HealthKitWriteStatus.writing.rawValue])
        }
    }
}
