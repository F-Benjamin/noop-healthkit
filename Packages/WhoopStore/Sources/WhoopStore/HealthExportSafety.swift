import Foundation

public enum HealthReconciliationMode: String, Codable, Sendable {
    case required, requestingAuthorization, reconciling, reconciled, newEpochOnly
    case failedRecoverable, failedTerminal
}

public enum HealthReconciliationStateMachine {
    public static func canTransition(from: HealthReconciliationMode,
                                     to: HealthReconciliationMode) -> Bool {
        switch (from, to) {
        case (.required, .requestingAuthorization), (.required, .reconciling),
             (.requestingAuthorization, .reconciling),
             (.requestingAuthorization, .failedRecoverable),
             (.requestingAuthorization, .failedTerminal),
             (.reconciling, .reconciled), (.reconciling, .newEpochOnly),
             (.reconciling, .failedRecoverable), (.reconciling, .failedTerminal),
             (.failedRecoverable, .required):
            return true
        default:
            return from == to
        }
    }

    public static func recoveredAfterLaunch(_ state: HealthReconciliationMode) -> HealthReconciliationMode {
        switch state {
        case .requestingAuthorization, .reconciling, .failedRecoverable: return .required
        default: return state
        }
    }
}

public struct HealthBackfillPlan: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var cursor: Int
    public var cancelled: Bool
    public init(start: Int, end: Int, cursor: Int? = nil, cancelled: Bool = false) {
        self.start = start; self.end = end; self.cursor = cursor ?? start; self.cancelled = cancelled
    }
    public var isComplete: Bool { cursor >= end }
    public mutating func advance(to value: Int) { cursor = min(end, max(cursor, value)) }
}

public struct HealthCircuitBreakerSnapshot: Codable, Equatable, Sendable {
    public var tripped: Bool
    public var reason: String?
    public var timestamp: Double?
    public var metric: HealthMetric?
    public init(tripped: Bool = false, reason: String? = nil, timestamp: Double? = nil,
                metric: HealthMetric? = nil) {
        self.tripped = tripped; self.reason = reason; self.timestamp = timestamp; self.metric = metric
    }
}

public struct HealthExportLoad: Equatable, Sendable {
    public let metric: HealthMetric
    public let pending: Int
    public let source: Int
    public let selected: Int
    public let retries: Int
    public let outputLastHour: Int
    public let outputLastDay: Int
    public let previousHourOutput: Int
    public init(metric: HealthMetric, pending: Int, source: Int, selected: Int, retries: Int,
                outputLastHour: Int, outputLastDay: Int, previousHourOutput: Int) {
        self.metric = metric; self.pending = pending; self.source = source; self.selected = selected
        self.retries = retries; self.outputLastHour = outputLastHour
        self.outputLastDay = outputLastDay; self.previousHourOutput = previousHourOutput
    }
}

public enum HealthExportSafetyPolicy {
    public static let maximumPending = 50_000
    public static let maximumRetries = 8
    public static let maximumOutputPerHour = 2_500
    public static let maximumOutputPerDay = 20_000

    public static func breakerReason(for load: HealthExportLoad) -> String? {
        if load.pending >= maximumPending { return "pending queue \(load.pending) exceeds \(maximumPending)" }
        if load.retries >= maximumRetries { return "repeated retries \(load.retries)" }
        if load.outputLastHour >= maximumOutputPerHour { return "hourly output \(load.outputLastHour) exceeds limit" }
        if load.outputLastDay >= maximumOutputPerDay { return "daily output \(load.outputLastDay) exceeds limit" }
        if load.source >= 1_000, load.selected * 2 > load.source {
            return "projection ratio \(load.selected)/\(load.source) is unexpectedly high"
        }
        if load.previousHourOutput > 0, load.outputLastHour > max(500, load.previousHourOutput * 4) {
            return "write rate accelerated more than 4x"
        }
        return nil
    }
}

public enum HealthSampleValidation {
    public static func rejectionReason(_ row: HealthMeasurement, now: Double) -> String? {
        guard row.startTs.isFinite, row.endTs.isFinite else { return "non-finite timestamp" }
        guard row.startTs >= 946_684_800 else { return "timestamp before supported epoch" } // 2000-01-01
        guard row.startTs <= now + 300, row.endTs <= now + 300 else { return "future timestamp" }
        guard row.endTs >= row.startTs else { return "end precedes start" }
        guard !row.deviceId.isEmpty, !row.sourceIdentifier.isEmpty else { return "missing source identity" }
        if let value = row.value, !value.isFinite { return "non-finite value" }
        switch row.metric {
        case .heartRate, .restingHeartRate:
            guard let v = row.value, (20...240).contains(v) else { return "impossible heart rate" }
        case .heartRateVariabilitySDNN:
            guard let v = row.value, (0...500).contains(v) else { return "impossible SDNN" }
        case .respiratoryRate:
            guard let v = row.value, (4...60).contains(v) else { return "impossible respiratory rate" }
        case .oxygenSaturation:
            guard let v = row.value, (0.70...1.0).contains(v), row.source == .measuredDevice else {
                return "untrusted oxygen saturation"
            }
        case .activeEnergy, .basalEnergy, .stepCount, .walkingRunningDistance, .cyclingDistance:
            guard let v = row.value, v >= 0 else { return "negative cumulative value" }
        case .sleepStage, .workout:
            guard row.endTs > row.startTs else { return "empty interval" }
        case .vo2Max:
            guard let v = row.value, (5...100).contains(v) else { return "impossible VO2 max" }
        }
        return nil
    }
}

public enum HealthBatchCommitPlanner {
    public static func chunks<T>(_ values: [T], size: Int = 25) -> [[T]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: values.count, by: size).map {
            Array(values[$0..<min($0 + size, values.count)])
        }
    }

    /// Executes and commits one chunk at a time. A later failure cannot roll a prior acknowledgement
    /// back into pending state, which is the key retry invariant for HealthKit's non-transactional API.
    public static func execute<T>(_ values: [T], size: Int = 25,
                                  save: ([T]) async throws -> Void,
                                  commit: ([T]) async throws -> Void) async throws {
        for chunk in chunks(values, size: size) {
            try Task.checkCancellation()
            try await save(chunk)
            try await commit(chunk)
            await Task.yield()
        }
    }
}

public enum HealthTimestampSemantics {
    /// Parses a persisted physiological day in a fixed calendar. Reprocessing after DST or travel
    /// therefore cannot move an existing sample or change its sync identity.
    public static func utcDayBounds(_ day: String) -> (start: Double, end: Double)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day) else { return nil }
        return (date.timeIntervalSince1970, date.timeIntervalSince1970 + 86_400)
    }
}
