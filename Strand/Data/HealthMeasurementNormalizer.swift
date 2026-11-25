import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics
import StrandImport

/// Converts vendor-decoded store rows into the canonical, vendor-independent health queue.
/// It knows store records and physiological validation rules, but has no HealthKit dependency.
enum HealthMeasurementNormalizer {
    struct Result: Sendable { let heartRates: Int; let sdnn: Int; let hasMore: Bool; let cursor: Int }

    static func normalizeNextSlice(store: WhoopStore, deviceId: String,
                                   now: Int = Int(Date().timeIntervalSince1970),
                                   sliceSeconds: Int = 20 * 60,
                                   cursorKey customCursorKey: String? = nil,
                                   initialStart: Int? = nil, endLimit: Int? = nil,
                                   context: HealthRateContext = .background) async throws -> Result {
        let cursorKey = customCursorKey ?? "normalize.health.v1.\(deviceId)"
        let completedEnd = min(max(0, now - 5), endLimit ?? .max)
        let initial = initialStart ?? max(0, completedEnd - sliceSeconds)
        // Normal export is deliberately future-focused. If the app was suspended or a prior queue
        // stalled, fast-forward this dedicated cursor to the fresh window instead of rebuilding a
        // historical backlog. Source HR remains untouched in hrSample for NOOP analytics.
        let storedCursor = try await store.cursor(cursorKey)
        let cursor = max(storedCursor ?? initial, initial)
        let end = min(completedEnd, cursor + sliceSeconds)
        guard end > cursor else { return Result(heartRates: 0, sdnn: 0, hasMore: false, cursor: cursor) }

        let hr = try await store.hrSamples(deviceId: deviceId, from: cursor, to: end - 1,
                                           limit: sliceSeconds * 4)
        let rr = try await store.rrIntervals(deviceId: deviceId, from: cursor, to: end - 1,
                                             limit: sliceSeconds * 4)
        let processed = Date().timeIntervalSince1970
        let heartRateRows = hr.compactMap { sample -> HealthMeasurement? in
            guard (30...220).contains(sample.bpm) else { return nil }
            return HealthMeasurement(
                id: "device:\(deviceId):heartRate:\(sample.ts)", metric: .heartRate,
                startTs: Double(sample.ts), endTs: Double(sample.ts), value: Double(sample.bpm),
                unit: .countPerMinute, deviceId: deviceId, source: .measuredDevice,
                quality: .valid, sourceIdentifier: "whoop-decoded-hr-v1",
                clockEpoch: deviceId, rateContext: context, processedAt: processed)
        }

        var rows: [HealthMeasurement] = []
        var sdnnCount = 0
        for (minute, beats) in Dictionary(grouping: rr, by: { $0.ts / 60 * 60 }).sorted(by: { $0.key < $1.key }) {
            let values = beats.map { Double($0.rrMs) }
            let clean = cleanedRR(values)
            guard clean.count >= 40, Double(values.count - clean.count) / Double(max(1, values.count)) <= 0.20 else { continue }
            let mean = clean.reduce(0, +) / Double(clean.count)
            let sdnn = sqrt(clean.reduce(0) { $0 + pow($1 - mean, 2) } / Double(clean.count - 1))
            guard sdnn.isFinite, (0...500).contains(sdnn) else { continue }
            rows.append(HealthMeasurement(
                id: "device:\(deviceId):sdnn:v1:\(minute)", metric: .heartRateVariabilitySDNN,
                startTs: Double(minute), endTs: Double(minute + 60), value: sdnn,
                unit: .millisecond, deviceId: deviceId, source: .derivedByNoop, quality: .valid,
                sourceIdentifier: "whoop-rr-sdnn-v2", clockEpoch: deviceId,
                rateContext: context,
                metadataJSON: "{\"algorithm\":\"SDNN sample SD; 60s; 11-beat median v2\"}",
                processedAt: processed))
            sdnnCount += 1
        }
        let allRows = heartRateRows + rows
        for metric in [HealthMetric.heartRate, .heartRateVariabilitySDNN] {
            _ = try await store.reconcileHealthMeasurementSnapshot(
                metric: metric, deviceId: deviceId, from: Double(cursor), to: Double(end),
                currentIdentifiers: Set(allRows.filter { $0.metric == metric }.map(\.id)))
        }
        try await store.upsertProjectedHealthMeasurements(heartRateRows)
        try await store.upsertHealthMeasurements(rows)
        try await store.setCursor(cursorKey, end)
        return Result(heartRates: hr.count, sdnn: sdnnCount, hasMore: end < completedEnd, cursor: end)
    }

    private static func cleanedRR(_ rr: [Double]) -> [Double] {
        rr.enumerated().compactMap { index, value in
            guard (300...2000).contains(value) else { return nil }
            let neighbours = (max(0, index - 5)...min(rr.count - 1, index + 5))
                .filter { $0 != index }.map { rr[$0] }.filter { (300...2000).contains($0) }.sorted()
            guard neighbours.count >= 2 else { return nil }
            let m = neighbours.count / 2
            let median = neighbours.count.isMultiple(of: 2)
                ? (neighbours[m - 1] + neighbours[m]) / 2 : neighbours[m]
            return abs(value - median) <= 0.20 * median ? value : nil
        }
    }

    static func normalizeDaily(_ rows: [DailyMetric], deviceId: String, now: Date = Date(),
                               allowMeasuredSpO2: Bool = false) -> [HealthMeasurement] {
        var out: [HealthMeasurement] = []
        func add(_ metric: HealthMetric, _ unit: HealthUnit, _ value: Double,
                 _ day: String, _ start: Date, _ end: Date, _ source: MeasurementSource) {
            guard value.isFinite else { return }
            out.append(.init(id: "device:\(deviceId):\(metric.rawValue):\(day)", metric: metric,
                startTs: start.timeIntervalSince1970, endTs: end.timeIntervalSince1970,
                value: value, unit: unit, deviceId: deviceId, source: source, quality: .valid,
                sourceIdentifier: "noop-daily-\(metric.rawValue)-v1"))
        }
        for row in rows {
            guard let bounds = HealthTimestampSemantics.utcDayBounds(row.day) else { continue }
            let start = Date(timeIntervalSince1970: bounds.start)
            let end = min(Date(timeIntervalSince1970: bounds.end), now)
            let instant = max(start, end.addingTimeInterval(-1))
            if let v = row.restingHr, (20...240).contains(v) {
                out.append(.init(id: "device:\(deviceId):restingHeartRate:\(row.day)", metric: .restingHeartRate,
                    startTs: instant.timeIntervalSince1970, endTs: instant.timeIntervalSince1970,
                    value: Double(v), unit: .countPerMinute, deviceId: deviceId,
                    source: .derivedByNoop, quality: .valid,
                    sourceIdentifier: "noop-primary-sleep-session-resting-hr",
                    metadataJSON: "{\"algorithm\":\"primary-sleep-session-resting-hr\",\"version\":1}"))
            }
            if let v = row.respRateBpm, (4...60).contains(v) { add(.respiratoryRate, .breathsPerMinute, v, row.day, instant, instant, .derivedByNoop) }
            if allowMeasuredSpO2, let v = row.spo2Pct, (70...100).contains(v) {
                add(.oxygenSaturation, .fraction, v / 100, row.day, instant, instant, .measuredDevice)
            }
            if let v = row.steps, v >= 0 { add(.stepCount, .count, Double(v), row.day, start, end, .derivedByNoop) }
            if let v = row.activeKcalEst, v >= 0 { add(.activeEnergy, .kilocalorie, v, row.day, start, end, .estimatedByNoop) }
        }
        return out
    }

    static func normalizeSleep(_ sessions: [CachedSleepSession], deviceId: String) -> [HealthMeasurement] {
        let blocks = sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) }
        // Session timestamps are absolute. A fixed UTC grouping prevents a later trip/time-zone change
        // from changing an already recorded night's identity during reconciliation.
        let groups = SleepStageTotals.bridgedNightGroups(blocks, offsetSec: 0).map { group in
            group.indices.map { i in HealthWriteback.SleepFragment(startTs: sessions[i].startTs,
                effectiveStartTs: sessions[i].effectiveStartTs, endTs: sessions[i].endTs,
                stagesJSON: sessions[i].stagesJSON) }
        }
        var out: [HealthMeasurement] = []
        for entry in HealthWriteback.mergedSleepPlan(groups: groups) {
            let base = "device:\(deviceId):sleep:\(entry.keyStartTs)"
            out.append(.init(id: base + ":inBed", metric: .sleepStage,
                startTs: Double(entry.spanStart), endTs: Double(entry.spanEnd), value: nil, unit: nil,
                categoryValue: HealthSleepStage.inBed.rawValue, deviceId: deviceId,
                source: .derivedByNoop, quality: .valid,
                sourceIdentifier: "noop-sleep-night-v2", clockEpoch: deviceId))
            for (i, interval) in entry.intervals.enumerated() {
                let stage: HealthSleepStage
                switch interval.kind { case .awake: stage = .awake; case .light: stage = .core
                case .deep: stage = .deep; case .rem: stage = .rem; case .unspecified: stage = .unspecified }
                out.append(.init(id: base + ":stage:\(i)", metric: .sleepStage,
                    startTs: Double(interval.start), endTs: Double(interval.end), value: nil, unit: nil,
                    categoryValue: stage.rawValue, deviceId: deviceId,
                    source: .derivedByNoop, quality: .valid,
                    sourceIdentifier: "noop-sleep-stage-v2", clockEpoch: deviceId))
            }
        }
        return out
    }

    static func normalizeWorkouts(_ rows: [WorkoutRow], deviceId: String) -> [HealthMeasurement] {
        rows.compactMap { row in
            guard row.endTs > row.startTs,
                  let data = try? JSONEncoder().encode(HealthWorkoutPayload(
                    sport: row.sport, energyKcal: row.energyKcal, distanceM: row.distanceM)),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return HealthMeasurement(id: "device:\(deviceId):workout:\(row.startTs):\(row.sport)",
                metric: .workout, startTs: Double(row.startTs), endTs: Double(row.endTs),
                value: nil, unit: nil, deviceId: deviceId, source: .derivedByNoop,
                quality: .valid, sourceIdentifier: "noop-workout-v2", clockEpoch: deviceId,
                rateContext: .workout, metadataJSON: json)
        }
    }

    private static let healthDay: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"; return f
    }()
}
