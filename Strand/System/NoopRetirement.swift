import Foundation

enum NoopRetirement {
    static let key = "noop.lifecycle.retired.v1"
    static var isRetired: Bool { UserDefaults.standard.bool(forKey: key) }

    static func persist() {
        UserDefaults.standard.set(true, forKey: key)
        UserDefaults.standard.synchronize()
    }
}
