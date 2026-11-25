#if os(iOS)
import Foundation
import HealthKit
import UIKit
import WhoopStore

struct HealthKitRecentWritesAuditReport: Codable {
    struct Sample: Codable {
        var metric: String
        var uuid: String
        var syncIdentifier: String?
        var syncVersion: Int?
        var origin: String?
        var start: Double
        var end: Double
        var value: Double?
        var unit: String?
        var categoryValue: Int?
        var sourceBundle: String
        var sourceName: String
        var sourceVersion: String?
        var productType: String?
        var deviceName: String?
        var manufacturer: String?
        var model: String?
        var hardwareVersion: String?
        var firmwareVersion: String?
        var localStatus: String?
        var localUUID: String?
        var localUUIDMatches: Bool?
        var localAttempts: Int?
        var localLastError: String?
        var localWrittenAt: Double?
    }
    struct Metric: Codable {
        var metric: String
        var typeIdentifier: String
        var visibleNoopSamplesInSevenDays: Int
        var queryWasTruncated: Bool
        var latest: [Sample]
        var latestLocalRows: [LocalRow]
        var localStatusCountsInSevenDays: [String: Int]
    }
    struct LocalRow: Codable {
        var id: String
        var start: Double
        var status: String
        var attempts: Int
        var uuid: String?
        var writtenAt: Double?
        var lastError: String?
    }
    var generatedAt: Double
    var osVersion: String
    var osBuild: String
    var appVersion: String
    var bundleIdentifier: String
    var windowStart: Double
    var windowEnd: Double
    var deviceId: String
    var metrics: [Metric]
    var healthKitWrites: Int
    var healthKitDeletes: Int
    var notes: [String]
}

@MainActor
enum HealthKitRecentWritesAudit {
    private static let statuses: [HealthKitWriteStatus] = [
        .pending, .writing, .written, .failed, .invalid, .unsupported, .unauthorized,
        .pendingDeletion, .deleting, .deleted, .suppressedByProjectionPolicy,
        .suppressedByRateLimit, .expiredByExportBoundary
    ]

    static func run(store: HKHealthStore, local: WhoopStore, deviceId: String) async throws -> URL {
        let now = Date().timeIntervalSince1970
        let from = now - 7 * 86_400
        let sourcePredicate = HKQuery.predicateForObjects(from: HKSource.default())
        let datePredicate = HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: from),
                                                        end: Date(timeIntervalSince1970: now + 1),
                                                        options: [.strictStartDate])
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [sourcePredicate, datePredicate])
        var metrics: [HealthKitRecentWritesAuditReport.Metric] = []

        for metric in HealthMetric.allCases {
            guard let definition = HealthKitMetricRegistry.definitions[metric], definition.readable,
                  let type = sampleType(for: definition) else { continue }
            let limit = 5_000
            let samples = try await query(store: store, type: type, predicate: predicate, limit: limit)
                .filter { $0.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier }
            var localByID: [String: HealthMeasurement] = [:]
            var statusCounts: [String: Int] = [:]
            for status in statuses {
                let count = try await local.healthMeasurementCount(metric: metric, deviceId: deviceId,
                                                                   statuses: [status], from: from, to: now + 1)
                if count > 0 { statusCounts[status.rawValue] = count }
                if [.written, .failed, .writing, .pending, .unauthorized].contains(status) {
                    let rows = try await local.healthMeasurements(metric: metric, deviceId: deviceId,
                                                                  statuses: [status], from: from, to: now + 1,
                                                                  limit: 10_000)
                    for row in rows { localByID[row.id] = row }
                }
            }
            let latest = samples.sorted { $0.startDate > $1.startDate }.prefix(20).map { sample in
                let syncID = sample.metadata?[HKMetadataKeySyncIdentifier] as? String
                let row = syncID.flatMap { localByID[$0] }
                let quantity = sample as? HKQuantitySample
                let category = sample as? HKCategorySample
                return HealthKitRecentWritesAuditReport.Sample(
                    metric: metric.rawValue, uuid: sample.uuid.uuidString,
                    syncIdentifier: syncID,
                    syncVersion: sample.metadata?[HKMetadataKeySyncVersion] as? Int,
                    origin: sample.metadata?["NOOPOrigin"] as? String,
                    start: sample.startDate.timeIntervalSince1970,
                    end: sample.endDate.timeIntervalSince1970,
                    value: definition.unit.flatMap { quantity?.quantity.doubleValue(for: $0) },
                    unit: definition.unit?.unitString, categoryValue: category?.value,
                    sourceBundle: sample.sourceRevision.source.bundleIdentifier,
                    sourceName: sample.sourceRevision.source.name,
                    sourceVersion: sample.sourceRevision.version,
                    productType: sample.sourceRevision.productType,
                    deviceName: sample.device?.name, manufacturer: sample.device?.manufacturer,
                    model: sample.device?.model, hardwareVersion: sample.device?.hardwareVersion,
                    firmwareVersion: sample.device?.firmwareVersion,
                    localStatus: row?.healthKitStatus.rawValue, localUUID: row?.healthKitUUID,
                    localUUIDMatches: row?.healthKitUUID.map { $0 == sample.uuid.uuidString },
                    localAttempts: row?.healthKitAttempts, localLastError: row?.healthKitLastError,
                    localWrittenAt: row?.healthKitWrittenAt)
            }
            let latestLocal = localByID.values.sorted { $0.startTs > $1.startTs }.prefix(30).map {
                HealthKitRecentWritesAuditReport.LocalRow(id: $0.id, start: $0.startTs,
                    status: $0.healthKitStatus.rawValue, attempts: $0.healthKitAttempts,
                    uuid: $0.healthKitUUID, writtenAt: $0.healthKitWrittenAt,
                    lastError: $0.healthKitLastError)
            }
            metrics.append(.init(metric: metric.rawValue, typeIdentifier: type.identifier,
                                 visibleNoopSamplesInSevenDays: samples.count,
                                 queryWasTruncated: samples.count == limit,
                                 latest: Array(latest), latestLocalRows: Array(latestLocal),
                                 localStatusCountsInSevenDays: statusCounts))
            print("[RecentWritesAudit] metric=\(metric.rawValue) healthKit=\(samples.count) local=\(statusCounts)")
            await Task.yield()
        }

        let report = HealthKitRecentWritesAuditReport(
            generatedAt: now, osVersion: UIDevice.current.systemVersion,
            osBuild: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown", windowStart: from, windowEnd: now,
            deviceId: deviceId, metrics: metrics, healthKitWrites: 0, healthKitDeletes: 0,
            notes: ["Strict read-only audit", "All HealthKit queries are bounded to seven days and 5,000 objects per metric",
                    "No save, correction, delete, reconciliation, normalization, or BLE work is executed"])
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("healthkit-recent-writes-audit.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    private static func sampleType(for definition: HealthKitMetricDefinition) -> HKSampleType? {
        guard let identifier = definition.identifier else { return nil }
        switch definition.kind {
        case .quantity: return HKObjectType.quantityType(forIdentifier: .init(rawValue: identifier))
        case .category: return HKObjectType.categoryType(forIdentifier: .init(rawValue: identifier))
        case .workout: return HKObjectType.workoutType()
        case .unsupported: return nil
        }
    }

    private static func query(store: HKHealthStore, type: HKSampleType,
                              predicate: NSPredicate, limit: Int) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit,
                                      sortDescriptors: [sort]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
    }
}
#endif
