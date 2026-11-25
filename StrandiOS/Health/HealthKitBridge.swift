#if os(iOS)
import Foundation
import Combine
import HealthKit
import WhoopStore
import WhoopProtocol
import StrandAnalytics
import StrandImport

/// Personal outbound-only NOOP fork: measured WHOOP 5 HR / RR-derived SDNN → HealthKit.
/// Existing NOOP BLE, SQLite, foreground and background lifecycle are reused.
@MainActor
final class HealthKitBridge: ObservableObject {
    enum RolloutPhase: Int, CaseIterable {
        case validateLocal = 1, lowVolume = 2, heartRate = 3, backfill = 4, allMetrics = 5
        var label: String {
            switch self {
            case .validateLocal: return "1/5 · Local validation only"
            case .lowVolume: return "2/5 · Low-volume metrics"
            case .heartRate: return "3/5 · Bounded heart rate"
            case .backfill: return "4/5 · Throttled history"
            case .allMetrics: return "5/5 · All compatible metrics"
            }
        }
    }
    enum AuthState: Equatable { case unknown, unavailable, denied, authorized, entitlementMissing }
    @Published private(set) var auth: AuthState = .unknown
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    @Published private(set) var lastError: String?
    @Published private(set) var savedDerivedSamples = 0
    @Published private(set) var syncProgress = ""
    @Published private(set) var syncStartedAt: Date?
    @Published private(set) var syncCompletedUnits = 0
    @Published private(set) var syncTotalUnits = 0
    @Published private(set) var rolloutPhase: RolloutPhase
    @Published private(set) var circuitBreakerStatus = "Armed · no anomaly"
    @Published private(set) var healthQueueStatus = "Queue not inspected yet"
    @Published private(set) var heartRateRetentionStatus = "HR storage not inspected yet"
    @Published private(set) var reconciliationStatus = "required"
    @Published private(set) var reconciledObjectCount = 0
    @Published private(set) var rebuiltOwnershipCount = 0
    @Published private(set) var exportEpoch: Date?
    @Published private(set) var authorizationRequestStatus = "notChecked"
    @Published private(set) var earliestAuthorizedSampleDates: [String: Double] = [:]
    @Published private(set) var historicalPendingExcluded = 0
    private static let rolloutKey = "healthkit.safeRolloutPhase.v1"
    private let store: HKHealthStore
    private let client: HealthKitClient
    private let writer: HealthKitWriter
    private let safety = HealthExportStateStore()
    private let repo: Repository
    /// The registry replaces the bootstrap `my-whoop` id with the strap serial after bonding.
    /// Resolve it for every export so a long-lived bridge follows that identity transition.
    private var noopDeviceId: String { repo.deviceId }
    private var pending = false
    /// Keep automatic work small enough that launch and BLE delivery never monopolise the main actor.
    /// The cursors are committed after every slice, so suspension or a kill resumes at the last slice.
    private static let automaticSliceSeconds = 20 * 60
    private static let healthKitBatchSize = 25
    private static var isReadOnlyRecentWritesAuditLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains("--noop-healthkit-readonly-recent-writes-audit")
    }
    init(repo: Repository, appleDeviceId: String) {
        self.repo = repo
        let client = SystemHealthKitClient()
        self.client = client
        self.store = client.healthStore
        self.writer = HealthKitWriter(client: client)
        // Every new binary starts closed. A stored phase is honored only after reconciliation and
        // while the persistent breaker is armed.
        let saved = RolloutPhase(rawValue: UserDefaults.standard.integer(forKey: Self.rolloutKey)) ?? .validateLocal
        self.rolloutPhase = [.reconciled, .newEpochOnly].contains(safety.reconciliation) && !safety.breaker.tripped
            ? saved : .validateLocal
        self.reconciliationStatus = safety.reconciliation.rawValue
        self.exportEpoch = safety.exportEpoch.map(Date.init(timeIntervalSince1970:))
        if safety.breaker.tripped {
            self.circuitBreakerStatus = "TRIPPED · \(safety.breaker.reason ?? "review required")"
        }
        if !HKHealthStore.isHealthDataAvailable() { auth = .unavailable }
        else if !Self.hasHealthKitEntitlement { auth = .entitlementMissing }
        logSafetyState(event: "initialized")
    }

    /// Deliberately explicit: a relaunch never clears a trip. The diagnostics screen may call this
    /// only after the queue/retry cause has been reviewed.
    func resetCircuitBreakerAfterReview() {
        safety.breaker = .init()
        circuitBreakerStatus = "Armed · manually reset after review"
    }

    func advanceSafeRollout() {
        guard safety.reconciliation == .reconciled || safety.reconciliation == .newEpochOnly,
              !safety.breaker.tripped else {
            lastError = "Apple Health reconciliation must finish before rollout can advance"
            return
        }
        guard let next = RolloutPhase(rawValue: rolloutPhase.rawValue + 1) else { return }
        rolloutPhase = next
        UserDefaults.standard.set(next.rawValue, forKey: Self.rolloutKey)
    }

    private func setRollout(_ phase: RolloutPhase) {
        rolloutPhase = phase
        UserDefaults.standard.set(phase.rawValue, forKey: Self.rolloutKey)
    }

    private func advanceAutomaticRolloutIfHealthy(_ local: WhoopStore) async throws {
        guard !safety.breaker.tripped, let boundary = safety.exportEpoch else { return }
        let deviceId = activeDeviceId(in: local)
        var exportable = 0
        for metric in HealthMetric.allCases {
            let failed = try await local.healthMeasurementCount(metric: metric, deviceId: deviceId,
                                                               statuses: [.failed], from: boundary,
                                                               to: Date().timeIntervalSince1970 + 1)
            guard failed == 0 else { return }
            let load = try await local.healthExportLoad(metric: metric, deviceId: deviceId,
                                                        notBefore: boundary)
            guard HealthExportSafetyPolicy.breakerReason(for: load) == nil else { return }
            exportable += load.pending
        }
        let key = "healthkit.futureRollout.previousExportable.v1"
        let previous = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(exportable, forKey: key)
        guard previous == 0 || exportable <= max(previous * 2, previous + 500) else { return }
        if rolloutPhase == .lowVolume { setRollout(.heartRate) }
        else if rolloutPhase == .heartRate { setRollout(.allMetrics) }
    }

    private func metricEnabled(_ metric: HealthMetric) -> Bool {
        switch rolloutPhase {
        case .validateLocal: return false
        case .lowVolume:
            return [.heartRateVariabilitySDNN, .restingHeartRate, .respiratoryRate,
                    .oxygenSaturation, .stepCount, .activeEnergy].contains(metric)
        case .heartRate, .backfill:
            return [.heartRate, .heartRateVariabilitySDNN, .restingHeartRate,
                    .respiratoryRate, .oxygenSaturation].contains(metric)
        case .allMetrics: return true
        }
    }

    private var writeTypes: Set<HKSampleType> {
        Set(HealthKitMetricRegistry.definitions.values.compactMap { definition in
            guard definition.writable, let identifier = definition.identifier else { return nil }
            switch definition.kind {
            case .quantity:
                return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier))
            case .category:
                return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier))
            case .workout:
                return HKObjectType.workoutType()
            case .unsupported:
                return nil
            }
        })
    }
    private var reconciliationReadTypes: Set<HKObjectType> { Set(writeTypes.map { $0 as HKObjectType }) }

    func requestAuthorization() async {
        guard !NoopRetirement.isRetired else { return }
        guard HKHealthStore.isHealthDataAvailable() else { auth = .unavailable; return }
        guard Self.hasHealthKitEntitlement else { auth = .entitlementMissing; return }
        do {
            _ = safety.transition(to: .requestingAuthorization)
            reconciliationStatus = safety.reconciliation.rawValue
            let requestStatus = try await client.authorizationRequestStatus(
                toShare: writeTypes, read: reconciliationReadTypes)
            authorizationRequestStatus = String(describing: requestStatus)
            logSafetyState(event: "authorization-status-checked")
            if requestStatus == .shouldRequest {
                logSafetyState(event: "authorization-requested")
                try await client.requestAuthorization(toShare: writeTypes, read: reconciliationReadTypes)
            }
            refreshAuthIfPreviouslyGranted()
            logSafetyState(event: "authorization-returned")
            try await reconcileOwnedHealthKitObjects()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            safety.recoverAfterFailure()
            reconciliationStatus = safety.reconciliation.rawValue
            logSafetyState(event: "authorization-or-reconciliation-failed", warning: error.localizedDescription)
        }
    }

    /// Existing HealthKit grants survive an app reinstall. Resume the mandatory ownership inventory
    /// without presenting another authorization sheet, and never enter an export path here.
    func reconcileExistingAuthorizationIfNeeded() async {
        guard !NoopRetirement.isRetired else { return }
        refreshAuthIfPreviouslyGranted()
        guard safety.reconciliation == .required else {
            logSafetyState(event: "existing-authorization-checked")
            return
        }
        do {
            _ = safety.transition(to: .requestingAuthorization)
            reconciliationStatus = safety.reconciliation.rawValue
            let requestStatus = try await client.authorizationRequestStatus(
                toShare: writeTypes, read: reconciliationReadTypes)
            authorizationRequestStatus = String(describing: requestStatus)
            logSafetyState(event: "authorization-status-checked")
            if requestStatus == .shouldRequest {
                logSafetyState(event: "authorization-requested")
                try await client.requestAuthorization(toShare: writeTypes, read: reconciliationReadTypes)
                logSafetyState(event: "authorization-returned")
            }
            try await reconcileOwnedHealthKitObjects()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            safety.recoverAfterFailure()
            reconciliationStatus = safety.reconciliation.rawValue
            logSafetyState(event: "reconciliation-failed", warning: error.localizedDescription)
        }
    }

    /// Rebuilds the local ownership map before any historical write. HealthKit intentionally does not
    /// expose read-denial status; an empty result is therefore handled conservatively as a new epoch.
    private func reconcileOwnedHealthKitObjects() async throws {
        guard safety.transition(to: .reconciling) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        reconciliationStatus = safety.reconciliation.rawValue
        logSafetyState(event: "reconciliation-started")
        earliestAuthorizedSampleDates = try await client.earliestAuthorizedSampleDates(for: reconciliationReadTypes)
        logSafetyState(event: "earliest-authorized-sample-dates-read")
        let owned = try await client.ownedObjects(for: writeTypes, limitPerType: 50_000)
        reconciledObjectCount = owned.count
        if owned.count >= 50_000 {
            safety.trip(reason: "owned HealthKit reconciliation reached bounded scan limit", metric: nil)
            _ = safety.transition(to: .failedTerminal)
            throw HealthKitWriter.CircuitBreakerError(reason: "reconciliation result requires paged review")
        }
        guard let local = await repo.storeHandle() else { throw CocoaError(.fileReadUnknown) }
        if owned.isEmpty {
            safety.beginNewEpoch()
            rebuiltOwnershipCount = 0
            let epoch = safety.exportEpoch ?? Date().timeIntervalSince1970
            historicalPendingExcluded = try await local.healthMeasurementCount(
                deviceId: activeDeviceId(in: local), statuses: [.pending, .failed, .unauthorized], before: epoch)
        } else {
            try await local.replaceHealthKitOwnership(owned)
            rebuiltOwnershipCount = try await local.reconcileHealthKitOwnedIdentifiers(
                Set(owned.map(\.syncIdentifier)), deviceId: activeDeviceId(in: local))
            _ = safety.transition(to: .reconciled)
        }
        reconciliationStatus = safety.reconciliation.rawValue
        exportEpoch = safety.exportEpoch.map(Date.init(timeIntervalSince1970:))
        logSafetyState(event: "reconciliation-completed")
    }

    private func logSafetyState(event: String, warning: String? = nil) {
        let breaker = safety.breaker
        let epoch = safety.exportEpoch.map { String($0) } ?? "none"
        let reason = breaker.reason ?? "none"
        let warningText = warning ?? "none"
        print("[HealthKitSafety] event=\(event) rollout=\(rolloutPhase.rawValue) auth=\(auth) requestStatus=\(authorizationRequestStatus) reconciliation=\(safety.reconciliation.rawValue) ownedFound=\(reconciledObjectCount) ownershipRebuilt=\(rebuiltOwnershipCount) earliestAuthorized=\(earliestAuthorizedSampleDates) exportEpoch=\(epoch) historicalPendingExcluded=\(historicalPendingExcluded) breakerTripped=\(breaker.tripped) breakerReason=\(reason) warning=\(warningText)")
    }

    private func enforcePersistentSafety(_ local: WhoopStore) async throws {
        let snapshot = safety.breaker
        if snapshot.tripped { throw HealthKitWriter.CircuitBreakerError(reason: snapshot.reason ?? "persisted trip") }
        let device = activeDeviceId(in: local)
        for metric in HealthMetric.allCases {
            let load = try await local.healthExportLoad(metric: metric, deviceId: device,
                                                        notBefore: safety.exportEpoch)
            if let reason = HealthExportSafetyPolicy.breakerReason(for: load) {
                safety.trip(reason: reason, metric: metric)
                circuitBreakerStatus = "TRIPPED · \(reason)"
                throw HealthKitWriter.CircuitBreakerError(reason: reason)
            }
        }
    }

    /// Share authorization is observable and per type. HR can work while HRV is declined.
    func refreshAuthIfPreviouslyGranted() {
        guard HKHealthStore.isHealthDataAvailable() else { auth = .unavailable; return }
        guard Self.hasHealthKitEntitlement else { auth = .entitlementMissing; return }
        let states = writeTypes.map { store.authorizationStatus(for: $0) }
        if states.contains(.sharingAuthorized) { auth = .authorized }
        else if states.contains(.sharingDenied) { auth = .denied }
        else { auth = .unknown }
    }

    @discardableResult
    func sync(days: Int = 30) async -> Bool { await writeBackAfterNewData() }

    /// The user-visible sync button follows the same future-only bounded path as automatic sync.
    /// Historical export is deliberately unavailable from normal application flow.
    @discardableResult
    func syncAllAvailable() async -> Bool {
        await writeBackAfterNewData()
    }

    @discardableResult
    func writeBackAfterNewData() async -> Bool {
        guard !NoopRetirement.isRetired else { return false }
        guard !Self.isReadOnlyRecentWritesAuditLaunch else { return false }
        guard rolloutPhase != .validateLocal else { return false }
        refreshAuthIfPreviouslyGranted()
        guard auth == .authorized else { return false }
        guard !syncing else { pending = true; return false }
        syncing = true
        syncStartedAt = Date()
        syncCompletedUnits = 0
        syncTotalUnits = 0
        defer { finishExclusiveSync() }
        guard let local = await repo.storeHandle() else {
            lastError = "Local database unavailable; export will retry"; return false
        }
        do {
            try await enforcePersistentSafety(local)
            guard let boundary = safety.exportEpoch else {
                throw HealthKitWriter.CircuitBreakerError(reason: "missing future-only export boundary")
            }
            let freshBoundary = max(boundary, Date().timeIntervalSince1970 - Double(Self.automaticSliceSeconds))
            _ = try await local.expireHealthMeasurements(metric: .heartRate,
                                                          deviceId: activeDeviceId(in: local),
                                                          before: freshBoundary)
            try await local.requeueUnauthorizedHealthKitWrites(
                deviceId: activeDeviceId(in: local),
                notBefore: boundary)
            try await local.requeueInterruptedHealthKitWrites(deviceId: activeDeviceId(in: local))
            _ = try await local.expireHealthMeasurements(deviceId: activeDeviceId(in: local), before: boundary)
            syncProgress = "Normalizing source measurements"
            let now = Int(Date().timeIntervalSince1970)
            _ = try await HealthMeasurementNormalizer.normalizeNextSlice(
                store: local, deviceId: activeDeviceId(in: local), now: now,
                cursorKey: "normalize.health.future.v1.\(activeDeviceId(in: local))",
                initialStart: max(Int(boundary.rounded(.up)), now - Self.automaticSliceSeconds),
                endLimit: now - 5, context: .background)
            bevelStatus = "Health sync in progress"
            syncProgress = "HR/HRV · preparing recent window"
            _ = try await writeBevel(whoopStore: local)
            // Rotate one cheap derived stream per automatic pass. This prevents launch from
            // constructing every Health sample at once while ensuring each stream makes progress.
            try await writeNextDerivedStream(whoopStore: local)
            let retention = try await local.pruneHighFrequencyHealthData(
                deviceId: activeDeviceId(in: local), now: Int(Date().timeIntervalSince1970))
            let deletedHR = retention["hrSample", default: 0] + retention["ppgHrSample", default: 0]
            if deletedHR > 0 { print("[HRRetention] deleted=\(deletedHR) bounded=true") }
            await refreshQueueDiagnostics(local)
            try await advanceAutomaticRolloutIfHealthy(local)
            lastSync = Date(); lastError = nil; return true
        } catch {
            if let breaker = error as? HealthKitWriter.CircuitBreakerError {
                circuitBreakerStatus = "TRIPPED · \(breaker.reason)"
            }
            lastError = "Apple Health export failed: \(error.localizedDescription)"
            return false
        }
    }

    func runReadOnlyRecentWritesAudit() async {
        syncing = true
        syncProgress = "Read-only recent HealthKit writes audit"
        defer { syncing = false; syncProgress = "" }
        do {
            guard let local = await repo.storeHandle() else { throw CocoaError(.fileReadUnknown) }
            let url = try await HealthKitRecentWritesAudit.run(store: store, local: local,
                                                               deviceId: activeDeviceId(in: local))
            print("[RecentWritesAudit] reportReady=\(url.path) healthKitWrites=0 deletes=0 corrections=0")
        } catch {
            print("[RecentWritesAudit] STOP error=\(error.localizedDescription) healthKitWrites=0 deletes=0 corrections=0")
        }
    }

    private func finishExclusiveSync() {
        syncing = false
        syncProgress = ""
        syncStartedAt = nil
        syncCompletedUnits = 0
        syncTotalUnits = 0
        if pending {
            pending = false
            // Coalesce any number of BLE/foreground triggers into one follow-up slice.
            Task { await writeBackAfterNewData() }
        }
    }

    private func refreshQueueDiagnostics(_ whoopStore: WhoopStore) async {
        let deviceId = activeDeviceId(in: whoopStore)
        guard let counts = try? await whoopStore.healthKitStatusCounts(deviceId: deviceId) else { return }
        healthQueueStatus = "pending \(counts[.pending, default: 0]) · written \(counts[.written, default: 0]) · " +
            "projected out \(counts[.suppressedByProjectionPolicy, default: 0]) · rate-limited \(counts[.suppressedByRateLimit, default: 0]) · " +
            "failed \(counts[.failed, default: 0])"
        if let retention = try? await whoopStore.heartRateRetentionDiagnostics(deviceId: deviceId) {
            let oldest = retention.oldestRawTimestamp.map {
                Date(timeIntervalSince1970: Double($0)).formatted(date: .abbreviated, time: .shortened)
            } ?? "none"
            let mb = Double(retention.storage.databaseBytes) / 1_048_576
            let walMB = Double(retention.storage.walBytes) / 1_048_576
            let last = retention.lastMaintenanceTimestamp.map {
                Date(timeIntervalSince1970: Double($0)).formatted(date: .abbreviated, time: .shortened)
            } ?? "never"
            heartRateRetentionStatus = "HR raw \(retention.rawRows) · oldest \(oldest) · last purge \(retention.deletedLastRun) · protected \(retention.protectedRows) · unclassified \(retention.unclassifiedRows) · DB \(String(format: "%.1f", mb)) MB · WAL \(String(format: "%.1f", walMB)) MB · maintenance \(last)"
        }
    }

    private func writeNextDerivedStream(whoopStore: WhoopStore) async throws {
        let key = "bevel.derived.roundRobin.v1"
        let phase = UserDefaults.standard.integer(forKey: key) % 3
        switch phase {
        case 0:
            syncProgress = "Daily metrics"
            try await writeDailyStream(whoopStore: whoopStore)
        case 1:
            syncProgress = "Sleep"
            try await writeSleepStream(whoopStore: whoopStore)
        default:
            syncProgress = "Workouts"
            try await writeWorkoutStream(whoopStore: whoopStore)
        }
        UserDefaults.standard.set((phase + 1) % 3, forKey: key)
        await Task.yield()
    }

    @Published private(set) var bevelStatus = "Waiting for WHOOP 5.0 BLE measurements"
    @Published private(set) var bevelSavedSamples = 0
    @Published private(set) var bevelSavedHeartRates = 0
    @Published private(set) var bevelSavedSDNN = 0
    private var lastBevelAttempt = Date.distantPast

    func writeBevelAfterBankedData() async {
        guard Date().timeIntervalSince(lastBevelAttempt) >= 30 else { return }
        lastBevelAttempt = Date()
        _ = await writeBackAfterNewData()
    }

    /// Processes one cursor-backed slice and reports whether older completed data remains.
    @discardableResult
    private func writeBevel(whoopStore: WhoopStore) async throws -> Bool {
        let exportDeviceId = activeDeviceId(in: whoopStore)
        let registry = DeviceRegistryStore(dbQueue: whoopStore.registryWriter)
        let paired = (try? registry.all())?.first(where: { $0.id == exportDeviceId })
        let hkDevice = HealthKitDeviceMapper.map(paired)
        let metrics: [HealthMetric] = [.heartRate, .heartRateVariabilitySDNN]
        var wrote = 0
        var hasMore = false

        for metric in metrics {
            guard metricEnabled(metric) else { continue }
            guard let definition = HealthKitMetricRegistry.definitions[metric] else { continue }
            while true {
                let tombstones = try await whoopStore.pendingHealthKitDeletions(
                    metric: metric, deviceId: exportDeviceId, limit: Self.healthKitBatchSize,
                    notBefore: safety.exportEpoch)
                guard !tombstones.isEmpty else { break }
                _ = try await writer.deleteOwned(tombstones, definition: definition, repository: whoopStore)
                await Task.yield()
                if tombstones.count < Self.healthKitBatchSize { break }
            }
            // HR drains in tiny units even though the canonical queue is already projected. This
            // independent cap prevents a restart from turning a legitimate same-day queue into a burst.
            let scanLimit = metric == .heartRate ? 5 : 25
            let rows = try await whoopStore.pendingHealthMeasurements(
                metric: metric, deviceId: exportDeviceId, limit: scanLimit,
                notBefore: safety.reconciliation == .newEpochOnly ? safety.exportEpoch : nil)
            let name = metric == .heartRate ? "Heart rate" : "HRV SDNN"
            syncTotalUnits = rows.count
            syncCompletedUnits = 0
            guard !rows.isEmpty else {
                syncProgress = "\(name) · queue empty"
                await Task.yield()
                continue
            }
            syncProgress = "\(name) · writing 1 batch"
            let written = try await writer.write(rows, definition: definition, device: hkDevice,
                                                  repository: whoopStore)
            syncCompletedUnits = rows.count
            wrote += written
            if metric == .heartRate { bevelSavedHeartRates += written }
            else { bevelSavedSDNN += written }
            hasMore = hasMore || rows.count == scanLimit
            await Task.yield()
        }
        bevelSavedSamples += wrote
        bevelStatus = wrote == 0
            ? "No pending normalized HR or SDNN measurement"
            : "Wrote \(wrote) normalized measurement\(wrote == 1 ? "" : "s") to Apple Health"
        return hasMore
    }

    // MARK: - Other WHOOP streams with a truthful HealthKit representation

    private func activeDeviceId(in whoopStore: WhoopStore) -> String {
        let persisted: String? = (try? DeviceRegistryStore(
            dbQueue: whoopStore.registryWriter).activeDeviceId()) ?? nil
        let trimmed = persisted?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed : nil) ?? noopDeviceId
    }

    /// Exports only values NOOP has already promoted from raw signals into a typed metric.
    /// Raw PPG/IMU, the unverified SpO2 candidate, thermal auxiliaries and activity-class bytes stay
    /// local because HealthKit has no honest destination for them. Apple's sleeping-wrist-temperature
    /// quantity is deliberately absent: iOS forbids third-party share authorization for that type.
    private func writeAvailableDerivedStreams(whoopStore: WhoopStore, days: Int = 14) async throws {
        try await writeDailyStream(whoopStore: whoopStore, days: days)
        await Task.yield()
        try await writeSleepStream(whoopStore: whoopStore, days: days)
        await Task.yield()
        try await writeWorkoutStream(whoopStore: whoopStore, days: days)
    }

    private func derivedRange(whoopStore: WhoopStore, days: Int) ->
        (deviceId: String, fromTs: Int, nowTs: Int, fromDay: String, toDay: String,
         rawIds: [String], computedIds: [String], now: Date)? {
        let deviceId = activeDeviceId(in: whoopStore)
        let now = Date()
        guard let requestedFrom = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return nil }
        let fromDate = max(requestedFrom, safety.exportEpoch.map(Date.init(timeIntervalSince1970:)) ?? now)
        let fromTs = Int(fromDate.timeIntervalSince1970)
        let nowTs = Int(now.timeIntervalSince1970)
        let fromDay = Self.healthDay.string(from: fromDate)
        let toDay = Self.healthDay.string(from: now)
        let rawIds = Array(Set(["my-whoop", deviceId]))
        let computedIds = Array(Set(["my-whoop-noop", deviceId + "-noop"]))
        return (deviceId, fromTs, nowTs, fromDay, toDay, rawIds, computedIds, now)
    }

    private func writeDailyStream(whoopStore: WhoopStore, days: Int = 14) async throws {
        guard let range = derivedRange(whoopStore: whoopStore, days: days) else { return }
        var dailies: [String: DailyMetric] = [:]
        for id in range.computedIds + range.rawIds {
            for row in (try? await whoopStore.dailyMetrics(deviceId: id, from: range.fromDay, to: range.toDay)) ?? [] {
                dailies[row.day] = row
            }
        }
        let registry = DeviceRegistryStore(dbQueue: whoopStore.registryWriter)
        let paired = (try? registry.all())?.first(where: { $0.id == range.deviceId })
        let hasMeasuredSpO2 = paired?.capabilities.contains(.spo2) == true
        let normalized = HealthMeasurementNormalizer.normalizeDaily(
            Array(dailies.values), deviceId: range.deviceId, now: range.now,
            allowMeasuredSpO2: hasMeasuredSpO2)
        for metric in [HealthMetric.restingHeartRate, .respiratoryRate, .oxygenSaturation,
                       .stepCount, .activeEnergy] {
            _ = try await whoopStore.reconcileHealthMeasurementSnapshot(
                metric: metric, deviceId: range.deviceId, from: Double(range.fromTs),
                to: Double(range.nowTs + 1),
                currentIdentifiers: Set(normalized.filter { $0.metric == metric }.map(\.id)))
        }
        try await whoopStore.upsertHealthMeasurements(normalized)
        try await writePending([.restingHeartRate, .respiratoryRate, .oxygenSaturation,
                                .stepCount, .activeEnergy], store: whoopStore, deviceId: range.deviceId)
    }

    private func writeSleepStream(whoopStore: WhoopStore, days: Int = 14) async throws {
        guard let range = derivedRange(whoopStore: whoopStore, days: days) else { return }
        var sleepsByStart: [Int: CachedSleepSession] = [:]
        for id in range.computedIds + range.rawIds {
            for session in (try? await whoopStore.sleepSessions(
                deviceId: id, from: range.fromTs, to: range.nowTs, limit: 500)) ?? [] {
                sleepsByStart[session.startTs] = session
            }
        }
        let rows = HealthMeasurementNormalizer.normalizeSleep(
            Array(sleepsByStart.values).sorted { $0.startTs < $1.startTs }, deviceId: range.deviceId)
        _ = try await whoopStore.reconcileHealthMeasurementSnapshot(
            metric: .sleepStage, deviceId: range.deviceId, from: Double(range.fromTs),
            to: Double(range.nowTs + 1), currentIdentifiers: Set(rows.map(\.id)))
        try await whoopStore.upsertHealthMeasurements(rows)
        try await writePending([.sleepStage], store: whoopStore, deviceId: range.deviceId)
    }

    private func writeWorkoutStream(whoopStore: WhoopStore, days: Int = 14) async throws {
        guard let range = derivedRange(whoopStore: whoopStore, days: days) else { return }
        var workoutsByKey: [String: WorkoutRow] = [:]
        for id in range.computedIds + range.rawIds {
            for workout in (try? await whoopStore.workouts(
                deviceId: id, from: range.fromTs, to: range.nowTs, limit: 1_000)) ?? []
                where workout.source != "apple-health" {
                workoutsByKey["\(workout.startTs):\(workout.sport)"] = workout
            }
        }
        let rows = HealthMeasurementNormalizer.normalizeWorkouts(
            Array(workoutsByKey.values).sorted { $0.startTs < $1.startTs }, deviceId: range.deviceId)
        _ = try await whoopStore.reconcileHealthMeasurementSnapshot(
            metric: .workout, deviceId: range.deviceId, from: Double(range.fromTs),
            to: Double(range.nowTs + 1), currentIdentifiers: Set(rows.map(\.id)))
        try await whoopStore.upsertHealthMeasurements(rows)
        try await writePending([.workout], store: whoopStore, deviceId: range.deviceId)
    }

    private func writePending(_ metrics: [HealthMetric], store whoopStore: WhoopStore,
                              deviceId: String) async throws {
        let device = healthDevice(in: whoopStore)
        for metric in metrics {
            guard metricEnabled(metric) else { continue }
            guard let definition = HealthKitMetricRegistry.definitions[metric] else { continue }
            while true {
                let tombstones = try await whoopStore.pendingHealthKitDeletions(
                    metric: metric, deviceId: deviceId, limit: Self.healthKitBatchSize,
                    notBefore: safety.exportEpoch)
                guard !tombstones.isEmpty else { break }
                _ = try await writer.deleteOwned(tombstones, definition: definition, repository: whoopStore)
                await Task.yield()
                if tombstones.count < Self.healthKitBatchSize { break }
            }
            while true {
                let rows = try await whoopStore.pendingHealthMeasurements(
                    metric: metric, deviceId: deviceId, limit: Self.healthKitBatchSize,
                    notBefore: safety.reconciliation == .newEpochOnly ? safety.exportEpoch : nil)
                guard !rows.isEmpty else { break }
                syncTotalUnits = rows.count; syncCompletedUnits = 0
                syncProgress = "\(metric.rawValue) · writing \(rows.count)"
                let count = try await writer.write(rows, definition: definition, device: device,
                                                   repository: whoopStore)
                savedDerivedSamples += count; syncCompletedUnits = rows.count
                await Task.yield()
                if rows.count < Self.healthKitBatchSize { break }
            }
        }
    }

    /// Requeues the recent sleep plan through the canonical writer. Stable sync identifiers and
    /// monotonically increasing versions replace corrected stages without creating duplicates.
    private func repairSleepWritebackIfNeeded(whoopStore: WhoopStore, days: Int = 14) async throws {
        let deviceId = activeDeviceId(in: whoopStore)
        let migrationKey = "bevel.sleep.writeback.canonical.v1.\(deviceId)"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        try await writeSleepStream(whoopStore: whoopStore, days: days)
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    private func healthDevice(in whoopStore: WhoopStore) -> HKDevice? {
        let id = activeDeviceId(in: whoopStore)
        let registry = DeviceRegistryStore(dbQueue: whoopStore.registryWriter)
        return HealthKitDeviceMapper.map((try? registry.all())?.first(where: { $0.id == id }))
    }

    private static let healthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let hasHealthKitEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            // No embedded profile = App Store build = properly signed. Assume present.
            return true
        }
        guard let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8)) else {
            // Profile present but unparseable — don't claim a missing entitlement off a parse failure;
            // assume present so we never wrongly down-route a real build.
            return true
        }
        let plistData = data.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return true
        }
        // The key is present (and truthy) on an entitled build; a free re-sign omits it entirely.
        return (entitlements["com.apple.developer.healthkit"] as? Bool) == true
    }()

}
#endif
