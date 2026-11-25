#if os(iOS)
import Foundation
import HealthKit
import WhoopStore

struct HealthKitReadback {
    let uuid: String
    let sourceBundle: String
    let device: HKDevice?
    let value: Double?
    let unitDescription: String?
    let start: Double
    let end: Double
    let syncIdentifier: String?
    let syncVersion: Int?
    let origin: String?
}

@MainActor
protocol HealthKitClient: AnyObject {
    var healthStore: HKHealthStore { get }
    func save(_ objects: [HKObject]) async throws
    func ownedObjects(for types: Set<HKSampleType>, limitPerType: Int) async throws -> [HealthKitOwnedObject]
    func deleteOwnedObjects(syncIdentifiers: Set<String>, type: HKSampleType) async throws
    func authorizationRequestStatus(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws -> HKAuthorizationRequestStatus
    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws
    func earliestAuthorizedSampleDates(for types: Set<HKObjectType>) async throws -> [String: Double]
    func readback(syncIdentifier: String, type: HKSampleType, unit: HKUnit?) async throws -> [HealthKitReadback]
}

@MainActor
final class SystemHealthKitClient: HealthKitClient {
    let healthStore: HKHealthStore
    init(store: HKHealthStore = HKHealthStore()) { healthStore = store }

    func save(_ objects: [HKObject]) async throws {
        try await healthStore.save(objects)
    }

    func authorizationRequestStatus(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws -> HKAuthorizationRequestStatus {
        try await healthStore.statusForAuthorizationRequest(toShare: toShare, read: read)
    }

    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws {
        try await healthStore.requestAuthorization(toShare: toShare, read: read)
    }

    func earliestAuthorizedSampleDates(for types: Set<HKObjectType>) async throws -> [String: Double] {
        // Xcode 26.x does not expose the iOS 27 limited-history API in its SDK. Returning an
        // unknown result is privacy-safe: reconciliation already treats zero visible objects as
        // newEpochOnly and never interprets this absence as proof of unrestricted read access.
        [:]
    }

    func readback(syncIdentifier: String, type: HKSampleType, unit: HKUnit?) async throws -> [HealthKitReadback] {
        let source = HKQuery.predicateForObjects(from: HKSource.default())
        let identifier = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier,
                                                     allowedValues: [syncIdentifier])
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [source, identifier])
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 10,
                                      sortDescriptors: nil) { _, values, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: values ?? []) }
            }
            healthStore.execute(query)
        }
        return samples.map { sample in
            let quantity = sample as? HKQuantitySample
            return HealthKitReadback(
                uuid: sample.uuid.uuidString,
                sourceBundle: sample.sourceRevision.source.bundleIdentifier,
                device: sample.device,
                value: unit.flatMap { quantity?.quantity.doubleValue(for: $0) },
                unitDescription: unit?.unitString,
                start: sample.startDate.timeIntervalSince1970,
                end: sample.endDate.timeIntervalSince1970,
                syncIdentifier: sample.metadata?[HKMetadataKeySyncIdentifier] as? String,
                syncVersion: sample.metadata?[HKMetadataKeySyncVersion] as? Int,
                origin: sample.metadata?["NOOPOrigin"] as? String)
        }
    }

    /// The source predicate is the ownership boundary. Metadata is used only after HealthKit has
    /// restricted results to the current NOOP source revision, so another app cannot be adopted.
    func ownedObjects(for types: Set<HKSampleType>, limitPerType: Int = 50_000) async throws -> [HealthKitOwnedObject] {
        var result: [HealthKitOwnedObject] = []
        let source = HKSource.default()
        let predicate = HKQuery.predicateForObjects(from: source)
        for type in types {
            let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limitPerType,
                                          sortDescriptors: nil) { _, samples, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: samples ?? []) }
                }
                healthStore.execute(query)
            }
            for sample in samples {
                guard sample.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier,
                      let id = sample.metadata?[HKMetadataKeySyncIdentifier] as? String,
                      sample.metadata?["NOOPOrigin"] != nil else { continue }
                result.append(.init(syncIdentifier: id, healthKitUUID: sample.uuid.uuidString,
                                    sampleType: type.identifier,
                                    startTs: sample.startDate.timeIntervalSince1970,
                                    endTs: sample.endDate.timeIntervalSince1970))
            }
        }
        return result
    }

    func deleteOwnedObjects(syncIdentifiers: Set<String>, type: HKSampleType) async throws {
        guard !syncIdentifiers.isEmpty else { return }
        let source = HKQuery.predicateForObjects(from: HKSource.default())
        let ids = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier,
                                              allowedValues: Array(syncIdentifiers))
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [source, ids])
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: syncIdentifiers.count, sortDescriptors: nil) { _, values, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: values ?? []) }
            }
            healthStore.execute(query)
        }
        guard samples.allSatisfy({ $0.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier }) else {
            throw CocoaError(.userCancelled)
        }
        if !samples.isEmpty { try await healthStore.delete(samples) }
    }
}
#endif
