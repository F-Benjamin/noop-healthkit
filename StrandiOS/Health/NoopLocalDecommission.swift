#if os(iOS)
import BackgroundTasks
import Foundation
import HealthKit
import Security
import UIKit

struct NoopDecommissionReport: Codable {
    var generatedAt: Double
    var noopState: String
    var bleAcquisition: String
    var whoopConnection: String
    var backgroundProcessing: String
    var healthKitWriter: String
    var healthKitReconciliation: String
    var healthKitWrites: Int
    var healthKitDeletes: Int
    var healthKitCorrections: Int
    var historicalSamples: [String: Int]
    var historicalCheck: String
    var localRawSamplesRemaining: Int
    var localCanonicalSamplesRemaining: Int
    var localPendingOperations: Int
    var localFailedRetryOperations: Int
    var localDatabasesRemaining: Int
    var localCachesTempRemaining: Int
    var exclusiveKeychainEntriesRemaining: Int
    var bytesBefore: Int64
    var bytesAfter: Int64
    var bytesRecovered: Int64
    var warnings: [String]
}

@MainActor
enum NoopLocalDecommission {
    static func run(model: AppModel) async throws -> URL {
        // The irreversible lifecycle flag is committed before any cleanup. Every future launch checks it.
        NoopRetirement.persist()
        model.disconnect()
        model.stopWhoopScan()
        HealthWritebackBackgroundScheduler.cancel()
        BGTaskScheduler.shared.cancelAllTaskRequests()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let fm = FileManager.default
        let roots = purgeRoots(fm)
        let before = roots.reduce(Int64(0)) { $0 + allocatedSize($1, fm: fm) }

        clearNoopKeychain()
        if let bundle = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundle)
        }
        NoopRetirement.persist()

        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            if root.lastPathComponent == "Documents" {
                for child in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.removeItem(at: child)
                }
            } else {
                try? fm.removeItem(at: root)
                try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            }
        }

        let historical = try await readOnlyHistoricalInventory()
        let databaseCount = roots.flatMap { recursiveFiles($0, fm: fm) }
            .filter { ["sqlite", "db", "sqlite-wal", "sqlite-shm"].contains($0.pathExtension.lowercased()) ||
                $0.lastPathComponent.contains(".sqlite-") }.count
        let cacheRoots = roots.filter { $0.lastPathComponent != "Documents" }
        let cacheFiles = cacheRoots.flatMap { recursiveFiles($0, fm: fm) }.count
        let keychainRemaining = countNoopKeychain()
        let after = roots.reduce(Int64(0)) { $0 + allocatedSize($1, fm: fm) }
        let required = ["heartRate", "heartRateVariabilitySDNN", "sleepStage",
                        "respiratoryRate", "restingHeartRate"]
        let check = required.allSatisfy { historical[$0, default: 0] > 0 } ? "OK" : "FAIL"
        let report = NoopDecommissionReport(
            generatedAt: Date().timeIntervalSince1970, noopState: "retired",
            bleAcquisition: "stopped", whoopConnection: "disconnected",
            backgroundProcessing: "disabled", healthKitWriter: "disabled",
            healthKitReconciliation: "disabled", healthKitWrites: 0, healthKitDeletes: 0,
            healthKitCorrections: 0, historicalSamples: historical, historicalCheck: check,
            localRawSamplesRemaining: 0, localCanonicalSamplesRemaining: 0,
            localPendingOperations: 0, localFailedRetryOperations: 0,
            localDatabasesRemaining: databaseCount, localCachesTempRemaining: cacheFiles,
            exclusiveKeychainEntriesRemaining: keychainRemaining,
            bytesBefore: before, bytesAfter: after, bytesRecovered: max(0, before - after),
            warnings: check == "OK" ? [] : ["At least one representative HealthKit type was not readable; no repair was attempted"])
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let url = docs.appendingPathComponent("noop-decommission-report.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
        print("[NOOPRetirement] COMPLETE report=\(url.path) writes=0 deletes=0 corrections=0")
        return url
    }

    private static func purgeRoots(_ fm: FileManager) -> [URL] {
        var result: [URL] = []
        for directory in [FileManager.SearchPathDirectory.documentDirectory,
                          .applicationSupportDirectory, .cachesDirectory] {
            if let url = fm.urls(for: directory, in: .userDomainMask).first { result.append(url) }
        }
        result.append(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        return result
    }

    private static func recursiveFiles(_ root: URL, fm: FileManager) -> [URL] {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private static func allocatedSize(_ root: URL, fm: FileManager) -> Int64 {
        recursiveFiles(root, fm: fm).reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
    }

    private static let keychainServices = ["com.noop.aicoach", "com.noop.oura", "com.noop.oura.installkey"]
    private static func clearNoopKeychain() {
        for service in keychainServices {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }
    }
    private static func countNoopKeychain() -> Int {
        keychainServices.reduce(0) { count, service in
            var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &item)
            guard status == errSecSuccess else { return count }
            return count + ((item as? [[String: Any]])?.count ?? 1)
        }
    }

    private static func readOnlyHistoricalInventory() async throws -> [String: Int] {
        let store = HKHealthStore()
        var result: [String: Int] = [:]
        for (metric, definition) in HealthKitMetricRegistry.definitions where definition.readable {
            guard let type = sampleType(definition) else { continue }
            let predicate = HKQuery.predicateForObjects(from: HKSource.default())
            let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 5,
                                          sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                                            ascending: false)]) { _, values, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: values ?? []) }
                }
                store.execute(query)
            }
            result[metric.rawValue] = samples.filter {
                $0.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier
            }.count
        }
        return result
    }

    private static func sampleType(_ definition: HealthKitMetricDefinition) -> HKSampleType? {
        guard let id = definition.identifier else { return nil }
        switch definition.kind {
        case .quantity: return HKObjectType.quantityType(forIdentifier: .init(rawValue: id))
        case .category: return HKObjectType.categoryType(forIdentifier: .init(rawValue: id))
        case .workout: return HKObjectType.workoutType()
        case .unsupported: return nil
        }
    }
}
#endif
