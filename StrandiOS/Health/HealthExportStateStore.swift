#if os(iOS)
import Foundation
import WhoopStore

@MainActor
final class HealthExportStateStore {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder(), decoder = JSONDecoder()
    private let breakerKey = "healthkit.circuitBreaker.v2"
    private let reconciliationKey = "healthkit.reconciliation.v2"
    private let epochKey = "healthkit.exportEpoch.v2"
    private let recoveryCutoffConsumedKey = "healthkit.initialRecoveryCutoffConsumed.v1"
    private let backfillKey = "healthkit.backfillPlan.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = HealthReconciliationMode(rawValue: defaults.string(forKey: reconciliationKey) ?? "") ?? .required
        let recovered = HealthReconciliationStateMachine.recoveredAfterLaunch(stored)
        if recovered != stored { defaults.set(recovered.rawValue, forKey: reconciliationKey) }
        // Migration for devices that already performed the authorized 11 September recovery with
        // the previous binary. Presence of its persistent floor means that action is consumed.
        if defaults.object(forKey: epochKey) != nil && recovered == .newEpochOnly {
            defaults.set(true, forKey: recoveryCutoffConsumedKey)
        }
    }

    var breaker: HealthCircuitBreakerSnapshot {
        get { defaults.data(forKey: breakerKey).flatMap { try? decoder.decode(HealthCircuitBreakerSnapshot.self, from: $0) } ?? .init() }
        set { defaults.set(try? encoder.encode(newValue), forKey: breakerKey) }
    }
    var reconciliation: HealthReconciliationMode {
        get { HealthReconciliationMode(rawValue: defaults.string(forKey: reconciliationKey) ?? "") ?? .required }
        set { defaults.set(newValue.rawValue, forKey: reconciliationKey) }
    }
    @discardableResult
    func transition(to next: HealthReconciliationMode) -> Bool {
        guard HealthReconciliationStateMachine.canTransition(from: reconciliation, to: next) else { return false }
        reconciliation = next
        return true
    }
    func recoverAfterFailure() {
        _ = transition(to: .failedRecoverable)
        _ = transition(to: .required)
    }
    var exportEpoch: Double? {
        get { defaults.object(forKey: epochKey) as? Double }
        set { defaults.set(newValue, forKey: epochKey) }
    }
    /// A fixed, one-time recovery floor. It is never recomputed at midnight. The legacy key is
    /// retained so installations that already abandoned older rows cannot accidentally revive them.
    var initialRecoveryCutoffConsumed: Bool {
        get { defaults.bool(forKey: recoveryCutoffConsumedKey) }
        set { defaults.set(newValue, forKey: recoveryCutoffConsumedKey) }
    }
    var backfillPlan: HealthBackfillPlan? {
        get { defaults.data(forKey: backfillKey).flatMap { try? decoder.decode(HealthBackfillPlan.self, from: $0) } }
        set {
            if let value = newValue, let data = try? encoder.encode(value) { defaults.set(data, forKey: backfillKey) }
            else { defaults.removeObject(forKey: backfillKey) }
        }
    }

    func trip(reason: String, metric: HealthMetric?, now: Double = Date().timeIntervalSince1970) {
        breaker = .init(tripped: true, reason: reason, timestamp: now, metric: metric)
    }
    func beginNewEpoch(now: Double = Date().timeIntervalSince1970) {
        exportEpoch = now; _ = transition(to: .newEpochOnly); backfillPlan = nil
    }

    /// Consumes the one-time recovery boundary. Repeated calls, including on later calendar days,
    /// return the original fixed floor and never create a new daily cutoff.
    @discardableResult
    func consumeInitialRecoveryCutoff(_ candidate: Double) -> Double {
        if initialRecoveryCutoffConsumed, let existing = exportEpoch { return existing }
        let advanced = max(exportEpoch ?? candidate, candidate)
        exportEpoch = advanced
        initialRecoveryCutoffConsumed = true
        backfillPlan = nil
        if reconciliation != .newEpochOnly { reconciliation = .newEpochOnly }
        return advanced
    }
}
#endif
