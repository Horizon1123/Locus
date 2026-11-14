import Foundation
import idevice

enum LocationEngineError: LocalizedError {
    case invalidIP
    case pairingRead
    case tunnelCreate
    case remoteServer
    case simulationCreate
    case locationSet
    case locationClear
    case notActive
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidIP: return "Tunnel IP is invalid. Check Settings → Tunnel IP (usually 10.7.0.1)."
        case .pairingRead: return "Could not read the RPPairing file. Generate one with idevice_pair in RPPairing mode."
        case .tunnelCreate: return "Could not reach the developer tunnel. Check LocalDevVPN and the tunnel address in Settings."
        case .remoteServer: return "Connected to the tunnel but RemoteXPC handshake failed."
        case .simulationCreate: return "Could not open Apple’s location simulation service."
        case .locationSet: return "Failed to set simulated coordinates."
        case .locationClear: return "Failed to clear simulated location."
        case .notActive: return "No active simulation session."
        case .cancelled: return "Location update cancelled."
        }
    }

    static func from(code: Int32) -> LocationEngineError {
        switch code {
        case 1: return .invalidIP
        case 2: return .pairingRead
        case 3: return .tunnelCreate
        case 9: return .remoteServer
        case 10: return .simulationCreate
        case 11: return .locationSet
        case 12: return .locationClear
        case 13: return .cancelled
        default: return .locationSet
        }
    }
}

/// Thin Swift wrapper around idevice’s DVT location simulation (injects into locationd).
enum LocationEngine {
    private static let queue = DispatchQueue(label: "com.chrismack.locus.location", qos: .userInitiated)
    private static let sessionStateLock = NSLock()
    private static var sessionActive = false

    private final class PendingRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private static var adapter: OpaquePointer?
    private static var handshake: OpaquePointer?
    private static var remoteServer: OpaquePointer?
    private static var locationSimulation: OpaquePointer?

    private static let ok: Int32 = 0
    private static let invalidIP: Int32 = 1
    private static let pairingRead: Int32 = 2
    private static let tunnelCreate: Int32 = 3
    private static let remoteServerCode: Int32 = 9
    private static let simulationCreate: Int32 = 10
    private static let locationSet: Int32 = 11
    private static let locationClear: Int32 = 12
    private static let cancelled: Int32 = 13

    static var isSessionActive: Bool {
        sessionStateLock.lock()
        defer { sessionStateLock.unlock() }
        return sessionActive
    }

    private static func updateSessionState(_ active: Bool) {
        sessionStateLock.lock()
        sessionActive = active
        sessionStateLock.unlock()
    }

    /// Enqueue before suspending, so a subsequent clear is always ordered after
    /// this request. Cancelling also prevents queued requests from opening a tunnel.
    static func setAsync(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) async -> Result<Void, LocationEngineError> {
        let request = PendingRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !request.isCancelled else {
                        continuation.resume(returning: .failure(.cancelled))
                        return
                    }
                    let code = setLocked(latitude: latitude, longitude: longitude, pairingPath: pairingPath, deviceIP: deviceIP, shouldCancel: { request.isCancelled })
                    continuation.resume(returning: code == ok ? .success(()) : .failure(.from(code: code)))
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    static func clearAsync() async -> Result<Void, LocationEngineError> {
        await withCheckedContinuation { continuation in
            queue.async {
                let code = clearLocked()
                continuation.resume(returning: code == ok ? .success(()) : .failure(.from(code: code)))
            }
        }
    }

    static func set(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) -> Result<Void, LocationEngineError> {
        var result: Result<Void, LocationEngineError> = .failure(.locationSet)
        queue.sync {
            let code = setLocked(latitude: latitude, longitude: longitude, pairingPath: pairingPath, deviceIP: deviceIP)
            result = code == ok ? .success(()) : .failure(.from(code: code))
        }
        return result
    }

    static func clear() -> Result<Void, LocationEngineError> {
        var result: Result<Void, LocationEngineError> = .failure(.notActive)
        queue.sync {
            let code = clearLocked()
            result = code == ok ? .success(()) : .failure(.from(code: code))
        }
        return result
    }

    private static func cleanup() {
        updateSessionState(false)
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            if let error = adapter_close(adapter) { idevice_error_free(error) }
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    private static func setLocked(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String, shouldCancel: () -> Bool = { false }) -> Int32 {
        let started = Date()
        NSLog("[Locus] native write started")
        defer { NSLog("[Locus] native write returned after %.2fs", Date().timeIntervalSince(started)) }
        NSLog("[Locus] native timeout patch v%u", locus_idevice_timeout_patch_version())
        idevice_set_global_timeout(5)
        if let locationSimulation {
            if let err = location_simulation_set(locationSimulation, latitude, longitude) {
                NSLog("[Locus] existing location channel failed; opening a fresh tunnel")
                idevice_error_free(err)
                cleanup()
            } else {
                return ok
            }
        }

        // Reject an invalid configured address rather than silently masking a typo.
        guard isValidAddress(deviceIP) else { return invalidIP }
        let port = TunnelConfig.targetPort
        var pairingHandle: OpaquePointer?
        if let pairingError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            idevice_error_free(pairingError)
            return pairingRead
        }
        guard let pairingHandle else { return pairingRead }
        defer { rp_pairing_file_free(pairingHandle) }

        var lastCode = tunnelCreate
        for host in candidateHosts(configured: deviceIP) {
            guard !shouldCancel() else { return cancelled }
            let code = openSession(host: host, port: port, pairing: pairingHandle,
                                   latitude: latitude, longitude: longitude)
            if code == ok { return ok }
            lastCode = code
        }
        return lastCode
    }

    static func candidateHosts(configured: String) -> [String] {
        var hosts: [String] = []
        for host in [configured, "127.0.0.1", "::1"] where !hosts.contains(host) {
            hosts.append(host)
        }
        return hosts
    }

    private static func isValidAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    /// Keep the sockaddr alive until the synchronous FFI call has returned.
    private static func openSession(host: String, port: UInt16, pairing: OpaquePointer,
                                    latitude: Double, longitude: Double) -> Int32 {
        NSLog("[Locus] trying developer endpoint [%@]:%u", host, UInt32(port))
        var address4 = sockaddr_in()
        address4.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address4.sin_family = sa_family_t(AF_INET)
        address4.sin_port = port.bigEndian
        let isV4 = host.withCString { inet_pton(AF_INET, $0, &address4.sin_addr) == 1 }
        let providerError: UnsafeMutablePointer<IdeviceFfiError>?
        if isV4 {
            providerError = withUnsafePointer(to: &address4) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.stride),
                        "LocusLocation", pairing, nil, nil, &adapter, &handshake)
                }
            }
        } else {
            var address6 = sockaddr_in6()
            address6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.stride)
            address6.sin6_family = sa_family_t(AF_INET6)
            address6.sin6_port = port.bigEndian
            guard host.withCString({ inet_pton(AF_INET6, $0, &address6.sin6_addr) == 1 }) else { return invalidIP }
            providerError = withUnsafePointer(to: &address6) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in6>.stride),
                        "LocusLocation", pairing, nil, nil, &adapter, &handshake)
                }
            }
        }
        if let providerError {
            logAndFree(providerError, stage: "tunnel", host: host)
            cleanup()
            return tunnelCreate
        }
        if let error = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            logAndFree(error, stage: "RemoteXPC", host: host)
            cleanup()
            return remoteServerCode
        }
        if let error = location_simulation_new(remoteServer, &locationSimulation) {
            logAndFree(error, stage: "location service", host: host)
            cleanup()
            return simulationCreate
        }
        // The location handle borrows remoteServer, whose owner survives until cleanup.
        if let error = location_simulation_set(locationSimulation, latitude, longitude) {
            logAndFree(error, stage: "location write", host: host)
            cleanup()
            return locationSet
        }
        updateSessionState(true)
        NSLog("[Locus] developer endpoint ready [%@]:%u", host, UInt32(port))
        return ok
    }

    private static func logAndFree(_ error: UnsafeMutablePointer<IdeviceFfiError>, stage: String, host: String) {
        let message = error.pointee.message.map { String(cString: $0) } ?? "No detail"
        NSLog("[Locus] %@ failed [%@] code=%d subcode=%d: %@", stage, host,
              error.pointee.code, error.pointee.sub_code, String(message.prefix(300)))
        idevice_error_free(error)
    }

    private static func clearLocked() -> Int32 {
        guard let locationSimulation else { return ok }
        let err = location_simulation_clear(locationSimulation)
        cleanup()
        if let err {
            idevice_error_free(err)
            return locationClear
        }
        return ok
    }
}
