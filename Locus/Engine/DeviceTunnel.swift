import Foundation

enum TunnelConfig {
    /// LocalDevVPN / SideStore-style loopback tunnel endpoint.
    static let defaultIP = "10.7.0.1"
    static let defaultsKey = "locus.targetDeviceIP"
    static let portKey = "locus.remotePairingPortOverride"

    static var targetPort: UInt16 {
        if let value = UserDefaults.standard.string(forKey: portKey),
           let port = UInt16(value.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 {
            return port
        }
        if let port = Bundle.main.object(forInfoDictionaryKey: "LocusTunnelPort") as? Int,
           (1...65535).contains(port) {
            return UInt16(port)
        }
        return 49152
    }

    @discardableResult
    static func setTargetPort(_ value: String) -> Bool {
        guard let port = UInt16(value.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else { return false }
        UserDefaults.standard.set(String(port), forKey: portKey)
        return true
    }

    static var targetIP: String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return defaultIP }
        return stored
    }

    static func setTargetIP(_ value: String) {
        UserDefaults.standard.set(value, forKey: defaultsKey)
    }
}
