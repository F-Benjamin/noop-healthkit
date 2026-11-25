#if os(iOS)
import HealthKit
import WhoopStore

enum HealthKitDeviceMapper {
    static func map(_ device: PairedDevice?) -> HKDevice? {
        guard let device else { return nil }
        let capabilities = Set(device.capabilities.compactMap { metric -> DeviceCapability? in
            switch metric {
            case .hr: return .heartRate; case .hrv: return .rrIntervals
            case .spo2: return .oxygenSaturation; case .skinTemp: return .skinTemperature
            case .steps: return .steps; case .sleep: return .sleep; case .strainLoad: return .workouts
            }
        })
        return map(HealthDevice(id: device.id, name: device.displayName, manufacturer: device.brand,
                                model: device.model.isEmpty ? nil : device.model, capabilities: capabilities))
    }

    static func map(_ device: HealthDevice) -> HKDevice {
        HKDevice(name: device.name, manufacturer: device.manufacturer, model: device.model,
                 hardwareVersion: device.hardwareVersion, firmwareVersion: device.firmwareVersion,
                 softwareVersion: nil, localIdentifier: device.id, udiDeviceIdentifier: nil)
    }
}
#endif
