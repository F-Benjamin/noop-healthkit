import Foundation

/// A measured 0x2A37 packet, never reconstructed from HR or historical record periods.
/// Raw bytes and packet identity survive SQLite retries; timestamps are HOST receipt times.
public struct BevelCapture: Codable, Equatable {
    public let id: String
    public let session: String
    public let receivedAt: Double
    public let bytes: [UInt8]
    public init(id: String = UUID().uuidString, session: String, receivedAt: Double, bytes: [UInt8]) {
        self.id = id; self.session = session; self.receivedAt = receivedAt; self.bytes = bytes
    }
    public var event: WhoopEvent {
        // Codable encoding of these finite values cannot fail for captures constructed by BLE.
        let json = (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return WhoopEvent(ts: Int(receivedAt), kind: "BEVEL_HR_" + id, payload: ["capture": .string(json)])
    }
    public init?(event: WhoopEvent) {
        guard event.kind.hasPrefix("BEVEL_HR_"), case let .string(json)? = event.payload["capture"],
              let data = json.data(using: .utf8),
              let capture = try? JSONDecoder().decode(Self.self, from: data),
              capture.receivedAt.isFinite, capture.receivedAt >= 0,
              event.kind == "BEVEL_HR_" + capture.id else { return nil }
        self = capture
    }
}

public enum BevelExport {
    public struct Measurement: Equatable {
        public let bpm: Int
        public let rrMS: [Double]
        public let contact: StandardHRContact
    }
    /// SIG Heart Rate Measurement: little endian; preserve 1/1024 s precision.
    /// Reject malformed optional fields instead of exporting a partially decoded packet.
    public static func parse(_ bytes: [UInt8]) -> Measurement? {
        guard let flags = bytes.first, flags & 0xE0 == 0 else { return nil }
        var i = 1
        func word() -> Int? {
            guard i + 1 < bytes.count else { return nil }
            defer { i += 2 }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8
        }
        let bpm: Int
        if flags & 1 != 0 {
            guard let value = word() else { return nil }; bpm = value
        } else {
            guard i < bytes.count else { return nil }; bpm = Int(bytes[i]); i += 1
        }
        if flags & 8 != 0, word() == nil { return nil }
        var rr: [Double] = []
        if flags & 16 != 0 {
            guard i < bytes.count, (bytes.count - i) % 2 == 0 else { return nil }
            while let value = word() { rr.append(Double(value) * 1000 / 1024) }
        }
        guard i == bytes.count else { return nil }
        return Measurement(bpm: bpm, rrMS: rr, contact: .fromMeasurementFlags(flags))
    }

    public struct Sample: Equatable {
        public enum Kind: String { case heartRate, sdnn }
        public let kind: Kind
        public let id: String
        public let version: Int
        public let start: Double
        public let end: Double
        public let value: Double
        public let acceptedBeats: Int
        public let rejectedBeats: Int
    }
    public struct Plan {
        public let samples: [Sample]
        public let status: String
    }
    /// One completed UTC minute, with a 5 s settling delay. Strict MVP gates, not a clinically
    /// validated artifact detector: one connection, <=3 s packet gaps, >=90% temporal coverage,
    /// RR duration 90–110% of the window, >=40 NN, <=20% rejected by range/local-median filter.
    /// No heartbeat series: host timestamps are not precise beat occurrence timestamps.
    public static func plan(captures: [BevelCapture], deviceID: String, minute: Int, now: Double) -> Plan {
        guard minute >= 0, minute % 60 == 0, Double(minute + 65) <= now else {
            return Plan(samples: [], status: "Waiting for a complete minute")
        }
        var ids = Set<String>()
        let packets = captures.filter {
            $0.receivedAt.isFinite && $0.receivedAt >= Double(minute) &&
            $0.receivedAt < Double(minute + 60) && ids.insert($0.id).inserted
        }.sorted { $0.receivedAt == $1.receivedAt ? $0.id < $1.id : $0.receivedAt < $1.receivedAt }
        let decoded = packets.compactMap { packet -> (BevelCapture, Measurement)? in
            guard let m = parse(packet.bytes) else { return nil }; return (packet, m)
        }
        var samples = decoded.compactMap { packet, m -> Sample? in
            guard (30...220).contains(m.bpm), m.contact != .supportedNotDetected else { return nil }
            return Sample(kind: .heartRate, id: "bevel:\(deviceID):hr:\(packet.id)", version: 1,
                          start: packet.receivedAt, end: packet.receivedAt, value: Double(m.bpm),
                          acceptedBeats: 0, rejectedBeats: 0)
        }
        func result(_ reason: String) -> Plan { Plan(samples: samples, status: reason) }
        guard !packets.isEmpty else { return result("No BLE packets") }
        guard decoded.count == packets.count else { return result("Malformed BLE packet; SDNN withheld") }
        guard Set(packets.map(\.session)).count == 1 else { return result("Connection changed; SDNN withheld") }
        guard decoded.allSatisfy({ $0.1.contact != .supportedNotDetected && (30...220).contains($0.1.bpm) }) else {
            return result("Sensor off wrist or invalid HR; SDNN withheld")
        }
        // A WHOOP 5 may omit R-R from an isolated 0x2A37 notification and deliver the next
        // measured interval in a later notification. Judge continuity from R-R-bearing packets;
        // the duration gate below still requires essentially a full minute of actual intervals.
        let rrPackets = decoded.filter { !$0.1.rrMS.isEmpty }
        guard let first = rrPackets.first?.0, let last = rrPackets.last?.0 else {
            return result("R-R missing; SDNN withheld")
        }
        guard
              first.receivedAt <= Double(minute + 3), last.receivedAt >= Double(minute + 57),
              zip(rrPackets, rrPackets.dropFirst()).allSatisfy({ $1.0.receivedAt - $0.0.receivedAt <= 3 }) else {
            return result("Incomplete R-R coverage; SDNN withheld")
        }
        let rr = rrPackets.flatMap { $0.1.rrMS }
        let duration = rr.reduce(0, +) / 1000
        guard (54...66).contains(duration) else { return result("Inconsistent R-R duration; SDNN withheld") }
        let clean = rr.enumerated().compactMap { i, value -> Double? in
            guard (300...2000).contains(value) else { return nil }
            // Eleven beats damp the reject-cascade caused when one missed optical pulse makes
            // its immediate neighbours look abnormal too. The interval itself is never included.
            let neighbours = (max(0, i - 5)...min(rr.count - 1, i + 5))
                .filter { $0 != i }.map { rr[$0] }.filter { (300...2000).contains($0) }.sorted()
            guard neighbours.count >= 2 else { return nil }
            let middle = neighbours.count / 2
            let median = neighbours.count % 2 == 0 ? (neighbours[middle - 1] + neighbours[middle]) / 2 : neighbours[middle]
            return abs(value - median) <= 0.2 * median ? value : nil
        }
        let rejected = rr.count - clean.count
        guard clean.count >= 40, Double(rejected) / Double(rr.count) <= 0.20 else {
            return result("Too many R-R artifacts; SDNN withheld")
        }
        let mean = clean.reduce(0, +) / Double(clean.count)
        let sdnn = (clean.reduce(0) { $0 + pow($1 - mean, 2) } / Double(clean.count - 1)).squareRoot()
        samples.append(Sample(kind: .sdnn, id: "bevel-v3:\(deviceID):sdnn:\(minute)",
                              version: 1, start: Double(minute),
                              end: Double(minute + 60), value: sdnn,
                              acceptedBeats: clean.count, rejectedBeats: rejected))
        return result("SDNN ready (\(clean.count) NN, \(rejected) rejected)")
    }
}
