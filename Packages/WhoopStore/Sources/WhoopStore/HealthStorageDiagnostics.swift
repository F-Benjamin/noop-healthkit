import Foundation
import GRDB

public enum HealthLocalRetention {
    public static let heartRateRawBufferSeconds = 24 * 60 * 60
    public static let heartRateMaintenanceIntervalSeconds = 60 * 60
    public static let heartRateRowsPerPass = 5_000
    public static let rrSeconds = 90 * 86_400
    public static let accelerometerSeconds = 30 * 86_400
    public static let terminalHealthExportSeconds = 180 * 86_400
}

public struct HealthStorageSnapshot: Equatable, Sendable {
    public let pageCount: Int
    public let freePageCount: Int
    public let pageSize: Int
    public let databaseBytes: Int64
    public let walBytes: Int64
    public let tableRows: [String: Int]
    public var liveSQLiteBytes: Int64 { Int64(max(0, pageCount - freePageCount) * pageSize) + walBytes }
}

public struct HeartRateRetentionDiagnostics: Equatable, Sendable {
    public let rawRows: Int
    public let oldestRawTimestamp: Int?
    public let deletedLastRun: Int
    public let protectedRows: Int
    public let unclassifiedRows: Int
    public let lastMaintenanceTimestamp: Int?
    public let storage: HealthStorageSnapshot
}

public struct HeartRateRetentionResult: Equatable, Sendable {
    public let ran: Bool
    public let deletedMeasuredRows: Int
    public let deletedPPGRows: Int
    public let protectedRows: Int
    public let unclassifiedRows: Int
    public let snapshot: HealthStorageSnapshot
    public var deletedRows: Int { deletedMeasuredRows + deletedPPGRows }
}

extension WhoopStore {
    private static func retentionCursor(_ suffix: String, _ deviceId: String) -> String {
        "maintenance.health.hr.v2.\(suffix).\(deviceId)"
    }

    /// Removes only old raw seconds which canonical projection explicitly made non-exportable.
    /// The selected source rows survive at their context policy's resolution. Every unresolved,
    /// active, failed, correction, owned or tombstone row is fail-closed and remains local.
    public func maintainHeartRateRetention(deviceId: String, now: Int,
                                           maxRows: Int = HealthLocalRetention.heartRateRowsPerPass,
                                           force: Bool = false) async throws -> HeartRateRetentionResult {
        let lastKey = Self.retentionCursor("last", deviceId)
        let deletedKey = Self.retentionCursor("deleted", deviceId)
        let protectedKey = Self.retentionCursor("protected", deviceId)
        if !force, let last = try await cursor(lastKey),
           now - last < HealthLocalRetention.heartRateMaintenanceIntervalSeconds {
            let d = try await heartRateRetentionDiagnostics(deviceId: deviceId, now: now)
            return .init(ran: false, deletedMeasuredRows: 0, deletedPPGRows: 0,
                         protectedRows: d.protectedRows, unclassifiedRows: d.unclassifiedRows,
                         snapshot: d.storage)
        }

        let cutoff = now - HealthLocalRetention.heartRateRawBufferSeconds
        let limit = max(1, maxRows)
        let counts = try syncWrite { db -> (Int, Int, Int, Int) in
            func deleteDiscardable(_ table: String, _ rowLimit: Int) throws -> Int {
                guard rowLimit > 0 else { return 0 }
                try db.execute(sql: """
                    DELETE FROM \(table) WHERE rowid IN (
                      SELECT raw.rowid FROM \(table) raw
                      WHERE raw.deviceId = ? AND raw.ts < ?
                        AND EXISTS (
                          SELECT 1 FROM healthMeasurement hm
                          WHERE hm.deviceId = raw.deviceId AND hm.metric = ?
                            AND CAST(hm.startTs AS INTEGER) = raw.ts
                            AND hm.healthKitStatus = ?
                            AND EXISTS (
                              SELECT 1 FROM healthMeasurement selected
                              WHERE selected.deviceId = hm.deviceId AND selected.metric = hm.metric
                                AND selected.rateContext = hm.rateContext
                                AND selected.healthKitStatus = ?
                                AND CAST(selected.startTs / CASE hm.rateContext
                                  WHEN 'background' THEN 60.0 WHEN 'sleep' THEN 30.0
                                  WHEN 'workout' THEN 5.0 WHEN 'historicalBackfill' THEN 60.0
                                  ELSE 1.0 END AS INTEGER)
                                  = CAST(hm.startTs / CASE hm.rateContext
                                  WHEN 'background' THEN 60.0 WHEN 'sleep' THEN 30.0
                                  WHEN 'workout' THEN 5.0 WHEN 'historicalBackfill' THEN 60.0
                                  ELSE 1.0 END AS INTEGER)
                            )
                        )
                        AND NOT EXISTS (
                          SELECT 1 FROM healthMeasurement hm
                          WHERE hm.deviceId = raw.deviceId AND hm.metric = ?
                            AND CAST(hm.startTs AS INTEGER) = raw.ts
                            AND hm.healthKitStatus != ?
                        )
                        AND NOT EXISTS (
                          SELECT 1 FROM healthMeasurement hm
                          JOIN healthKitOwnedObject owned ON owned.syncIdentifier = hm.id
                          WHERE hm.deviceId = raw.deviceId AND hm.metric = ?
                            AND CAST(hm.startTs AS INTEGER) = raw.ts
                        )
                      ORDER BY raw.ts LIMIT ?
                    )
                    """, arguments: [deviceId, cutoff, HealthMetric.heartRate.rawValue,
                                      HealthKitWriteStatus.suppressedByProjectionPolicy.rawValue,
                                      HealthKitWriteStatus.written.rawValue,
                                      HealthMetric.heartRate.rawValue,
                                      HealthKitWriteStatus.suppressedByProjectionPolicy.rawValue,
                                      HealthMetric.heartRate.rawValue, rowLimit])
                return db.changesCount
            }
            let measured = try deleteDiscardable("hrSample", limit)
            let ppg = try deleteDiscardable("ppgHrSample", limit - measured)
            let protected = try Self.protectedRawHRCount(db, deviceId, cutoff)
            let unclassified = try Self.unclassifiedRawHRCount(db, deviceId, cutoff)
            for (key, value) in [(lastKey, now), (deletedKey, measured + ppg), (protectedKey, protected)] {
                try db.execute(sql: """
                    INSERT INTO cursors (name, value) VALUES (?, ?)
                    ON CONFLICT(name) DO UPDATE SET value = excluded.value
                    """, arguments: [key, value])
            }
            return (measured, ppg, protected, unclassified)
        }
        if counts.0 + counts.1 > 0 { try await checkpointWAL() }
        return .init(ran: true, deletedMeasuredRows: counts.0, deletedPPGRows: counts.1,
                     protectedRows: counts.2, unclassifiedRows: counts.3,
                     snapshot: try await healthStorageSnapshot())
    }

    public func heartRateRetentionDiagnostics(deviceId: String,
                                               now: Int = Int(Date().timeIntervalSince1970)) async throws
        -> HeartRateRetentionDiagnostics {
        let cutoff = now - HealthLocalRetention.heartRateRawBufferSeconds
        let values = try syncRead { db -> (Int, Int?, Int, Int) in
            let raw = try Int.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM hrSample WHERE deviceId = ?) +
                       (SELECT COUNT(*) FROM ppgHrSample WHERE deviceId = ?)
                """, arguments: [deviceId, deviceId]) ?? 0
            let oldest = try Int.fetchOne(db, sql: """
                SELECT MIN(ts) FROM (SELECT ts FROM hrSample WHERE deviceId = ?
                UNION ALL SELECT ts FROM ppgHrSample WHERE deviceId = ?)
                """, arguments: [deviceId, deviceId])
            return (raw, oldest, try Self.protectedRawHRCount(db, deviceId, cutoff),
                    try Self.unclassifiedRawHRCount(db, deviceId, cutoff))
        }
        return .init(rawRows: values.0, oldestRawTimestamp: values.1,
                     deletedLastRun: try await cursor(Self.retentionCursor("deleted", deviceId)) ?? 0,
                     protectedRows: values.2, unclassifiedRows: values.3,
                     lastMaintenanceTimestamp: try await cursor(Self.retentionCursor("last", deviceId)),
                     storage: try await healthStorageSnapshot())
    }

    private static func protectedRawHRCount(_ db: Database, _ deviceId: String, _ cutoff: Int) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM (SELECT deviceId, ts FROM hrSample WHERE deviceId = ? AND ts < ?
              UNION ALL SELECT deviceId, ts FROM ppgHrSample WHERE deviceId = ? AND ts < ?) raw
            WHERE EXISTS (SELECT 1 FROM healthMeasurement hm
              WHERE hm.deviceId = raw.deviceId AND hm.metric = ? AND CAST(hm.startTs AS INTEGER) = raw.ts
                AND hm.healthKitStatus IN (?, ?, ?, ?, ?, ?))
            """, arguments: [deviceId, cutoff, deviceId, cutoff, HealthMetric.heartRate.rawValue,
                              HealthKitWriteStatus.pending.rawValue, HealthKitWriteStatus.failed.rawValue,
                              HealthKitWriteStatus.writing.rawValue, HealthKitWriteStatus.unauthorized.rawValue,
                              HealthKitWriteStatus.pendingDeletion.rawValue, HealthKitWriteStatus.deleting.rawValue]) ?? 0
    }

    private static func unclassifiedRawHRCount(_ db: Database, _ deviceId: String, _ cutoff: Int) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM (SELECT deviceId, ts FROM hrSample WHERE deviceId = ? AND ts < ?
              UNION ALL SELECT deviceId, ts FROM ppgHrSample WHERE deviceId = ? AND ts < ?) raw
            WHERE NOT EXISTS (SELECT 1 FROM healthMeasurement hm
              WHERE hm.deviceId = raw.deviceId AND hm.metric = ? AND CAST(hm.startTs AS INTEGER) = raw.ts)
            """, arguments: [deviceId, cutoff, deviceId, cutoff, HealthMetric.heartRate.rawValue]) ?? 0
    }

    /// Compatibility entry point: HR now uses the safe incremental policy; unrelated retention remains.
    public func pruneHighFrequencyHealthData(deviceId: String, now: Int) async throws -> [String: Int] {
        let hr = try await maintainHeartRateRetention(deviceId: deviceId, now: now)
        var result = ["hrSample": hr.deletedMeasuredRows, "ppgHrSample": hr.deletedPPGRows]
        let other = try syncWrite { db -> [String: Int] in
            var deleted: [String: Int] = [:]
            for (table, cutoff) in [("rrInterval", now - HealthLocalRetention.rrSeconds),
                                    ("gravitySample", now - HealthLocalRetention.accelerometerSeconds),
                                    ("ppgWaveformSample", now - HealthLocalRetention.accelerometerSeconds)] {
                try db.execute(sql: "DELETE FROM \(table) WHERE deviceId = ? AND ts < ?", arguments: [deviceId, cutoff])
                deleted[table] = db.changesCount
            }
            let cutoff = Double(now - HealthLocalRetention.terminalHealthExportSeconds)
            try db.execute(sql: """
                DELETE FROM healthMeasurement WHERE deviceId = ? AND startTs < ?
                AND healthKitStatus IN (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [deviceId, cutoff, HealthKitWriteStatus.written.rawValue,
                                  HealthKitWriteStatus.deleted.rawValue, HealthKitWriteStatus.invalid.rawValue,
                                  HealthKitWriteStatus.unsupported.rawValue, HealthKitWriteStatus.unauthorized.rawValue,
                                  HealthKitWriteStatus.suppressedByProjectionPolicy.rawValue,
                                  HealthKitWriteStatus.suppressedByRateLimit.rawValue])
            deleted["healthMeasurement"] = db.changesCount
            return deleted
        }
        result.merge(other) { $1 }
        return result
    }

    public func healthStorageSnapshot() async throws -> HealthStorageSnapshot {
        try syncRead { db in
            let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let free = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            let path = try String.fetchOne(db, sql: "SELECT file FROM pragma_database_list WHERE name = 'main'") ?? ""
            let names = ["rawBatch", "hrSample", "ppgHrSample", "rrInterval", "gravitySample",
                         "ppgWaveformSample", "healthMeasurement", "healthKitOwnedObject"]
            var counts: [String: Int] = [:]
            for name in names { counts[name] = (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(name)")) ?? 0 }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let walAttrs = try? FileManager.default.attributesOfItem(atPath: path + "-wal")
            return .init(pageCount: pageCount, freePageCount: free, pageSize: pageSize,
                         databaseBytes: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                         walBytes: (walAttrs?[.size] as? NSNumber)?.int64Value ?? 0, tableRows: counts)
        }
    }
}
