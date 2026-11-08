import Combine
import CoreLocation
import Foundation
import MapKit
import Network
import NetworkExtension
import UIKit
import UserNotifications

enum TravelMode: String, CaseIterable, Identifiable {
    case walk, run, cycle, drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Cycle"
        case .drive: return "Drive"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// Base meters per second before natural variation.
    var baseSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .drive: return 13.4
        }
    }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .drive: return .automobile
        }
    }
}

enum SpoofStatus: Equatable {
    case idle
    case connecting
    case active
    case reconnecting
    case dropped(String)

    var label: String {
        switch self {
        case .idle: return "Not Spoofing"
        case .connecting: return "Starting…"
        case .active: return "Spoofing"
        case .reconnecting: return "Reconnecting…"
        case .dropped: return "Interrupted"
        }
    }

    var isDropped: Bool {
        if case .dropped = self { return true }
        return false
    }
}

/// Fires `onChange` whenever the set of usable network interfaces changes
/// (Wi‑Fi ↔ cellular, Wi‑Fi lost, a VPN toggled…). The first callback after
/// `start()` only records the baseline and is not reported.
final class NetworkWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.chrismack.locus.netwatch")
    private var lastSignature: String?
    var onChange: (@Sendable (String) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let types: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .other]
            let used = types.filter { path.usesInterfaceType($0) }.map { "\($0)" }.joined(separator: "+")
            let names = path.availableInterfaces.map { $0.name }.sorted().joined(separator: ",")
            let signature = "\(path.status) [\(used)] {\(names)}"
            if signature == self.lastSignature { return }
            let isBaseline = self.lastSignature == nil
            self.lastSignature = signature
            if isBaseline { return }
            self.onChange?(signature)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

@MainActor
final class SpoofSession: ObservableObject {
    @Published var status: SpoofStatus = .idle
    @Published var pin: CLLocationCoordinate2D?
    @Published var simulated: CLLocationCoordinate2D?
    @Published var travelMode: TravelMode = .walk
    @Published var mapStyleIndex: Int = 0
    @Published var lastError: String?
    @Published private(set) var reconnectError: String?
    @Published var isBusy = false
    @Published var joystickActive = false
    @Published private(set) var lastSuccessfulWriteAt: Date?
    @Published private(set) var successfulWriteCount = 0
    @Published private(set) var lastTarget: CLLocationCoordinate2D?

    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []

    private var resendTimer: Timer?
    private var healthTimer: Timer?
    private var joystickTimer: Timer?
    private var routeTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var joystickVector: CGVector = .zero
    private let locationKeeper = BackgroundKeepAlive()
    private let audioKeepAlive = SilentAudioKeepAlive()
    private let netWatcher = NetworkWatcher()
    private var reconnectTask: Task<Void, Never>?
    private var resendTask: Task<Void, Never>?
    private var sessionGeneration = UUID()
    private var coordinateRevision = 0
    private var isStopping = false
    private var vpnObserver: NSObjectProtocol?
    private weak var activePairing: PairingStore?
    private var lastPersist = Date.distantPast
    private static let writeInterval: TimeInterval = 2

    private let favoritesKey = "locus.favorites"
    private let recentsKey = "locus.recents"
    private let persistKey = "locus.lastSpoof"
    private let targetKey = "locus.lastTarget"

    private struct CachedTarget: Codable {
        var latitude: Double
        var longitude: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    init() {
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.load(key: recentsKey)
        if let data = UserDefaults.standard.data(forKey: targetKey),
           let saved = try? JSONDecoder().decode(CachedTarget.self, from: data),
           CLLocationCoordinate2DIsValid(saved.coordinate) {
            lastTarget = saved.coordinate
            pin = saved.coordinate
        }

        // Wi‑Fi ↔ cellular switches (or a VPN toggle) can kill the developer
        // session even though LocalDevVPN still looks connected. Re-establish it
        // immediately instead of waiting for the next timer tick.
        netWatcher.onChange = { [weak self] signature in
            Task { @MainActor in
                self?.handleNetworkChange("network changed: \(signature)")
            }
        }
        netWatcher.start()
        vpnObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleNetworkChange("vpn status changed")
            }
        }
    }

    deinit {
        if let vpnObserver { NotificationCenter.default.removeObserver(vpnObserver) }
    }

    var isSpoofing: Bool {
        if case .active = status { return true }
        if case .reconnecting = status { return true }
        return false
    }

    func teleport(to coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        rememberTarget(coordinate)
        guard !isStopping else { return }
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        pin = coordinate
        apply(coordinate, pairing: pairing, markRecent: true)
    }

    func stop(pairing: PairingStore) {
        guard !isStopping else { return }
        isStopping = true
        sessionGeneration = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        routeTask?.cancel()
        routeTask = nil
        stopJoystick()
        stopResend()
        stopHealth()
        isBusy = true
        simulated = nil
        lastSuccessfulWriteAt = nil
        successfulWriteCount = 0
        activePairing = nil
        status = .idle
        reconnectError = nil
        clearPersistedSpoof()
        audioKeepAlive.stop()
        // Clear on the engine queue even if a reconnect is still opening its
        // tunnel. Cancellation cannot interrupt a native call already in progress.
        Task {
            let result = await LocationEngine.clearAsync()
            isBusy = false
            isStopping = false
            endBackground()
            locationKeeper.start()
            switch result {
            case .success:
                lastError = nil
            case .failure(let error):
                lastError = error.localizedDescription
                status = .dropped(error.localizedDescription)
                postDropNotification(error.localizedDescription)
            }
        }
    }

    /// Best-known real device coordinate (not the teleport pin).
    var realCoordinate: CLLocationCoordinate2D? {
        locationKeeper.lastKnownCoordinate
    }

    /// Start lightweight GPS updates for the map puck / locate button.
    func startLocationUpdates() {
        locationKeeper.start()
    }

    func startJoystick(pairing: PairingStore) {
        guard !isStopping else { return }
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        let start = simulated ?? pin ?? locationKeeper.lastKnownCoordinate
        guard let start else {
            lastError = "Drop a pin or teleport somewhere before using the joystick."
            return
        }
        if simulated == nil {
            apply(start, pairing: pairing, markRecent: false)
        }
        joystickActive = true
        joystickTimer?.invalidate()
        joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickJoystick(pairing: pairing)
            }
        }
    }

    func updateJoystick(vector: CGVector) {
        joystickVector = vector
    }

    func stopJoystick() {
        joystickActive = false
        joystickVector = .zero
        joystickTimer?.invalidate()
        joystickTimer = nil
    }

    func followRoute(_ coordinates: [CLLocationCoordinate2D], pairing: PairingStore) {
        guard !isStopping, pairing.hasPairingFile, coordinates.count >= 2 else { return }
        routeTask?.cancel()
        stopJoystick()
        let mode = travelMode
        routeTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            var previous = coordinates[0]
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.apply(previous, pairing: pairing, markRecent: true)
            }
            for next in coordinates.dropFirst() {
                if Task.isCancelled { break }
                let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
                var speed = mode.baseSpeed * Double.random(in: 0.88...1.12)
                speed = max(0.8, speed)
                let stepMeters: CLLocationDistance = min(12, max(4, speed * 0.5))
                let steps = max(1, Int(ceil(distance / stepMeters)))
                for i in 1...steps {
                    if Task.isCancelled { break }
                    let t = Double(i) / Double(steps)
                    let coord = CLLocationCoordinate2D(
                        latitude: previous.latitude + (next.latitude - previous.latitude) * t,
                        longitude: previous.longitude + (next.longitude - previous.longitude) * t
                    )
                    let delay = stepMeters / speed
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.apply(coord, pairing: pairing, markRecent: false)
                    }
                }
                previous = next
            }
        }
    }

    func addFavorite(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // Don't let a generic star overwrite a named favorite for the same spot.
        if let existing = favorites.first(where: { $0.id == place.id }),
           Self.isGenericFavoriteName(place.name),
           !Self.isGenericFavoriteName(existing.name) {
            return
        }
        favorites.removeAll { $0.id == place.id }
        favorites.insert(place, at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func renameFavorite(_ place: SavedPlace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        favorites[index].name = trimmed
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeFavorite(_ place: SavedPlace) {
        favorites.removeAll { $0.id == place.id }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        SavedPlace.save(recents, key: recentsKey)
    }

    /// Best display name for starring the current pin (search title, matching recent, etc.).
    func suggestedFavoriteName(for coordinate: CLLocationCoordinate2D, fallback: String? = nil) -> String {
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let favorite = favorites.first(where: { $0.id == SavedPlace(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude).id }),
           !Self.isGenericFavoriteName(favorite.name) {
            return favorite.name
        }
        if let recent = recents.first(where: {
            abs($0.latitude - coordinate.latitude) < 0.00015 && abs($0.longitude - coordinate.longitude) < 0.00015
        }), !Self.isGenericFavoriteName(recent.name) {
            return recent.name
        }
        return Self.coordinateLabel(coordinate)
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func isGenericFavoriteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Favorite" { return true }
        // Coordinate-looking labels from older teleports.
        let parts = trimmed.split(separator: ",")
        if parts.count == 2,
           Double(parts[0].trimmingCharacters(in: .whitespaces)) != nil,
           Double(parts[1].trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        return false
    }

    private func apply(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore, markRecent: Bool) {
        guard !isStopping else { return }
        persistSpoof(coordinate, force: markRecent)
        coordinateRevision += 1
        activePairing = pairing
        simulated = coordinate
        pin = coordinate
        if markRecent { pushRecent(coordinate) }
        // All writes share the asynchronous reconnect worker. A second tap only
        // changes its target; no UI action waits on the native network queue.
        startReconnect(to: coordinate, pairing: pairing, reason: "target changed")
    }

    private func tickJoystick(pairing: PairingStore) {
        guard joystickActive, reconnectTask == nil, let current = simulated else { return }
        let magnitude = hypot(joystickVector.dx, joystickVector.dy)
        guard magnitude > 0.08 else { return }
        let nx = joystickVector.dx / magnitude
        let ny = -joystickVector.dy / magnitude
        let speed = travelMode.baseSpeed * min(1.0, magnitude) * Double.random(in: 0.9...1.1)
        let dt = 0.25
        let meters = speed * dt
        let next = offset(coordinate: current, eastMeters: nx * meters, northMeters: ny * meters)
        apply(next, pairing: pairing, markRecent: false)
    }

    private func startResend(pairing: PairingStore) {
        resendTimer?.invalidate()
        let timer = Timer(timeInterval: Self.writeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopping, self.reconnectTask == nil,
                      self.resendTask == nil, let sim = self.simulated else { return }
                let generation = self.sessionGeneration
                let revision = self.coordinateRevision
                self.resendTask = Task { [weak self] in
                    guard let self else { return }
                    let result = await self.setOffMain(sim, pairing: pairing)
                    guard !Task.isCancelled, self.sessionGeneration == generation else { return }
                    self.resendTask = nil
                    if case .failure(let error) = result, self.coordinateRevision == revision,
                       self.reconnectTask == nil, let current = self.simulated {
                        NSLog("[Locus] periodic resend failed: %@", String(describing: error))
                        self.startReconnect(to: current, pairing: pairing, reason: "resend failed: \(error)")
                    }
                }
            }
        }
        // Keep the writer scheduled while the user pans the map or drags controls.
        RunLoop.main.add(timer, forMode: .common)
        resendTimer = timer
    }

    private func stopResend() {
        resendTask?.cancel()
        resendTask = nil
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private func startHealth(pairing: PairingStore) {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.reconnectTask == nil, let sim = self.simulated else { return }
                if self.status.isDropped || (self.isSpoofing && !LocationEngine.isSessionActive) {
                    self.startReconnect(to: sim, pairing: pairing, reason: "health check")
                }
            }
        }
    }

    private func stopHealth() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    // MARK: - Reconnect & persistence

    private struct PersistedSpoof: Codable {
        var latitude: Double
        var longitude: Double
        var bootTime: TimeInterval?
    }

    private static func bootTime() -> TimeInterval? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return TimeInterval(tv.tv_sec)
    }

    /// Save the target immediately; throttle only the separate active-session
    /// record. Reading kernel boot metadata must never be required to save a point.
    private func persistSpoof(_ coordinate: CLLocationCoordinate2D, force: Bool = false) {
        rememberTarget(coordinate)
        let now = Date()
        guard force || now.timeIntervalSince(lastPersist) > 2 else { return }
        lastPersist = now
        let value = PersistedSpoof(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            bootTime: Self.bootTime()
        )
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private func rememberTarget(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        if let lastTarget, lastTarget.latitude == coordinate.latitude,
           lastTarget.longitude == coordinate.longitude { return }
        let value = CachedTarget(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: targetKey)
        lastTarget = coordinate
    }

    private func clearPersistedSpoof() {
        UserDefaults.standard.removeObject(forKey: persistKey)
        lastPersist = .distantPast
    }

    /// Call on launch. Re-applies the last teleport after the app was killed or
    /// relaunched, but not after a phone reboot (iOS has dropped the override by then).
    func resumeIfNeeded(pairing: PairingStore) {
        activePairing = pairing
        guard !isStopping, status == .idle, reconnectTask == nil, pairing.hasPairingFile,
              let data = UserDefaults.standard.data(forKey: persistKey),
              let saved = try? JSONDecoder().decode(PersistedSpoof.self, from: data) else { return }
        guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: saved.latitude, longitude: saved.longitude)) else {
            clearPersistedSpoof()
            return
        }
        if let savedBoot = saved.bootTime, let currentBoot = Self.bootTime(), savedBoot != currentBoot {
            clearPersistedSpoof()
            return
        }
        let coordinate = CLLocationCoordinate2D(latitude: saved.latitude, longitude: saved.longitude)
        rememberTarget(coordinate)
        pin = coordinate
        simulated = coordinate
        startReconnect(to: coordinate, pairing: pairing, reason: "resume after relaunch")
    }

    /// Call when the app returns to the foreground: if we should be spoofing but the
    /// session is gone, bring it back.
    func reconnectIfNeeded(pairing: PairingStore) {
        activePairing = pairing
        guard !isStopping, reconnectTask == nil, let sim = simulated else { return }
        if status.isDropped || !LocationEngine.isSessionActive {
            startReconnect(to: sim, pairing: pairing, reason: "foreground")
        }
    }

    private func handleNetworkChange(_ reason: String) {
        NSLog("[Locus] %@", reason)
        guard let sim = simulated, let pairing = activePairing else { return }
        startReconnect(to: sim, pairing: pairing, reason: reason)
    }

    private func setOffMain(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore) async -> Result<Void, LocationEngineError> {
        let generation = sessionGeneration
        let path = pairing.pairingPath
        let ip = TunnelConfig.targetIP
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let result = await LocationEngine.setAsync(latitude: lat, longitude: lon, pairingPath: path, deviceIP: ip)
        if !Task.isCancelled, sessionGeneration == generation, case .success = result {
            recordSuccessfulWrite()
        }
        return result
    }

    /// A successful native write, not merely a connected VPN or an active timer.
    private func recordSuccessfulWrite() {
        lastSuccessfulWriteAt = Date()
        successfulWriteCount += 1
        NSLog("[Locus] location write succeeded (#%d)", successfulWriteCount)
    }

    /// Re-establish the developer session and re-send the last coordinate, off the
    /// main thread until it works or the user stops. Never gate on Wi-Fi or internet
    /// reachability: only the on-device tunnel needs to remain reachable.
    /// `LocationEngine.set` first tries the existing session, so a network change that
    /// didn't actually break anything costs one cheap call and no flicker.
    private func startReconnect(to coordinate: CLLocationCoordinate2D, pairing: PairingStore, reason: String) {
        guard !isStopping, reconnectTask == nil else { return }
        NSLog("[Locus] reconnect start (%@)", reason)
        stopResend()
        stopHealth()
        beginBackground()
        audioKeepAlive.start()
        let generation = sessionGeneration
        // .reconnecting (rather than .connecting) so the Stop button is available.
        status = .reconnecting
        reconnectError = nil
        reconnectTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                let target = self.simulated ?? coordinate
                let result = await self.setOffMain(target, pairing: pairing)
                if Task.isCancelled || self.sessionGeneration != generation { return }
                switch result {
                case .success:
                    // A tap or route update may have changed the target while
                    // the network operation was in flight. Apply that target first.
                    if let latest = self.simulated,
                       latest.latitude != target.latitude || latest.longitude != target.longitude {
                        continue
                    }
                    self.finishReconnect(at: target, pairing: pairing)
                    return
                case .failure(let error):
                    // Automatic retries must not reopen a blocking alert every
                    // time the user dismisses it. Keep the failure visible in
                    // the status bar while retrying the saved target.
                    self.reconnectError = error.localizedDescription
                    attempt += 1
                    NSLog("[Locus] reconnect attempt %d failed: %@", attempt, String(describing: error))
                    if attempt == 3 {
                        self.postDropNotification(error.localizedDescription)
                    }
                }
                // Keep retrying promptly after Wi-Fi loss instead of eventually
                // waiting 30 seconds between writes to the local tunnel.
                let delay = attempt == 1 ? 1 : Self.writeInterval
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func finishReconnect(at coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        NSLog("[Locus] reconnect succeeded")
        reconnectTask = nil
        simulated = coordinate
        pin = coordinate
        status = .active
        lastError = nil
        reconnectError = nil
        beginBackground()
        locationKeeper.start()
        audioKeepAlive.start()
        startResend(pairing: pairing)
        startHealth(pairing: pairing)
        persistSpoof(coordinate, force: true)
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        pushNamedRecent(
            name: Self.coordinateLabel(coordinate),
            coordinate: coordinate
        )
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        recents.removeAll {
            abs($0.latitude - place.latitude) < 0.00015 && abs($0.longitude - place.longitude) < 0.00015
        }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        SavedPlace.save(recents, key: recentsKey)
    }

    private func beginBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackground()
        }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func postDropNotification(_ message: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Locus spoof dropped"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func offset(coordinate: CLLocationCoordinate2D, eastMeters: Double, northMeters: Double) -> CLLocationCoordinate2D {
        let earth = 6378137.0
        let dLat = northMeters / earth * (180 / .pi)
        let dLon = eastMeters / (earth * cos(coordinate.latitude * .pi / 180)) * (180 / .pi)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + dLat, longitude: coordinate.longitude + dLon)
    }
}
