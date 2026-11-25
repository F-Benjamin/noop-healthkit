import Foundation

/// Canonical projection rules shared by normalization, queue maintenance and the final writer.
/// Keeping them below HealthKit prevents the local queue and the Apple Health adapter from drifting.
public enum HealthProjectionPolicies {
    public static func policy(for metric: HealthMetric, context: HealthRateContext) -> HealthKitProjectionPolicy {
        guard metric == .heartRate else {
            return HealthKitProjectionPolicy(mode: .preserve, maxSamplesPerDay: 2_000)
        }
        switch context {
        case .background, .historicalBackfill:
            return .init(mode: .downsample, minimumInterval: 60,
                         maxSamplesPerHour: 60, maxSamplesPerDay: 1_440)
        case .sleep:
            return .init(mode: .downsample, minimumInterval: 30,
                         maxSamplesPerHour: 120, maxSamplesPerDay: 1_440)
        case .workout:
            return .init(mode: .downsample, minimumInterval: 5,
                         maxSamplesPerHour: 720, maxSamplesPerDay: 4_320,
                         allowLiveHighFrequency: true)
        case .manual:
            return .init(mode: .eventOnly, maxSamplesPerHour: 30, maxSamplesPerDay: 100)
        }
    }
}

public enum HealthProjectionSelector {
    public struct Result: Sendable, Equatable {
        public let selected: [HealthMeasurement]
        public let suppressed: [HealthMeasurement]
    }

    /// Deterministically chooses real source records. No interpolation or fabricated aggregate is used.
    public static func select(_ rows: [HealthMeasurement], policy: HealthKitProjectionPolicy,
                              occupiedBuckets: Set<Int64> = []) -> Result {
        let ordered = rows.sorted { ($0.startTs, $0.id) < ($1.startTs, $1.id) }
        guard policy.mode != .doNotWrite else { return .init(selected: [], suppressed: ordered) }
        guard policy.mode == .downsample, let interval = policy.minimumInterval, interval > 0 else {
            return .init(selected: ordered, suppressed: [])
        }
        var selected: [HealthMeasurement] = []
        var suppressed: [HealthMeasurement] = []
        for (bucket, group) in Dictionary(grouping: ordered, by: { Int64(floor($0.startTs / interval)) })
            .sorted(by: { $0.key < $1.key }) {
            if occupiedBuckets.contains(bucket) { suppressed.append(contentsOf: group) }
            else if let first = group.first {
                selected.append(first); suppressed.append(contentsOf: group.dropFirst())
            }
        }
        return .init(selected: selected, suppressed: suppressed)
    }
}
