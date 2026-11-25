#if os(iOS)
import HealthKit
import WhoopStore

enum HealthKitSampleKind { case quantity, category, workout, unsupported }

struct HealthKitMetricDefinition {
    let metric: HealthMetric
    let identifier: String?
    let kind: HealthKitSampleKind
    let unit: HKUnit?
    let readable: Bool
    let writable: Bool
    let projection: HealthKitProjectionPolicy
}

enum HealthKitMetricRegistry {
    private static let preserve = HealthKitProjectionPolicy(mode: .preserve, maxSamplesPerDay: 2_000)
    private static let event = HealthKitProjectionPolicy(mode: .eventOnly, maxSamplesPerDay: 100)
    static let definitions: [HealthMetric: HealthKitMetricDefinition] = [
        .heartRate: .init(metric: .heartRate, identifier: HKQuantityTypeIdentifier.heartRate.rawValue,
                         kind: .quantity, unit: .count().unitDivided(by: .minute()), readable: true, writable: true,
                         projection: .init(mode: .downsample, minimumInterval: 60,
                                           maxSamplesPerHour: 60, maxSamplesPerDay: 1_440)),
        .heartRateVariabilitySDNN: .init(metric: .heartRateVariabilitySDNN,
                         identifier: HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue,
                         kind: .quantity, unit: .secondUnit(with: .milli), readable: true, writable: true, projection: preserve),
        .respiratoryRate: .init(metric: .respiratoryRate, identifier: HKQuantityTypeIdentifier.respiratoryRate.rawValue,
                         kind: .quantity, unit: .count().unitDivided(by: .minute()), readable: true, writable: true, projection: preserve),
        .oxygenSaturation: .init(metric: .oxygenSaturation, identifier: HKQuantityTypeIdentifier.oxygenSaturation.rawValue,
                         kind: .quantity, unit: .percent(), readable: true, writable: true, projection: preserve),
        .activeEnergy: .init(metric: .activeEnergy, identifier: HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
                         kind: .quantity, unit: .kilocalorie(), readable: true, writable: true, projection: preserve),
        .basalEnergy: .init(metric: .basalEnergy, identifier: HKQuantityTypeIdentifier.basalEnergyBurned.rawValue,
                         kind: .quantity, unit: .kilocalorie(), readable: true, writable: true, projection: preserve),
        .stepCount: .init(metric: .stepCount, identifier: HKQuantityTypeIdentifier.stepCount.rawValue,
                         kind: .quantity, unit: .count(), readable: true, writable: true, projection: preserve),
        .walkingRunningDistance: .init(metric: .walkingRunningDistance,
                         identifier: HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
                         kind: .quantity, unit: .meter(), readable: true, writable: true, projection: preserve),
        .cyclingDistance: .init(metric: .cyclingDistance, identifier: HKQuantityTypeIdentifier.distanceCycling.rawValue,
                         kind: .quantity, unit: .meter(), readable: true, writable: true, projection: preserve),
        .restingHeartRate: .init(metric: .restingHeartRate, identifier: HKQuantityTypeIdentifier.restingHeartRate.rawValue,
                         kind: .quantity, unit: .count().unitDivided(by: .minute()), readable: true, writable: true, projection: preserve),
        .vo2Max: .init(metric: .vo2Max, identifier: HKQuantityTypeIdentifier.vo2Max.rawValue,
                         kind: .quantity, unit: HKUnit(from: "ml/kg*min"), readable: true, writable: true, projection: preserve),
        .sleepStage: .init(metric: .sleepStage, identifier: HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
                         kind: .category, unit: nil, readable: true, writable: true, projection: event),
        .workout: .init(metric: .workout, identifier: HKWorkoutType.workoutType().identifier,
                         kind: .workout, unit: nil, readable: true, writable: true, projection: event)
    ]

    /// HR cadence is a NOOP safety/product decision, not an Apple rule. Context is persisted with
    /// every canonical row so workout/manual behavior can evolve without reclassifying old history.
    static func projection(for metric: HealthMetric, context: HealthRateContext) -> HealthKitProjectionPolicy {
        guard metric == .heartRate else { return definitions[metric]?.projection ?? .init(mode: .doNotWrite) }
        return HealthProjectionPolicies.policy(for: metric, context: context)
    }
}
#endif
