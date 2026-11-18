from pathlib import Path

def edit(name, old, new):
    p=Path(name);s=p.read_text();assert s.count(old)==1,(name,old[:80],s.count(old));p.write_text(s.replace(old,new))

edit('Waypoint/Services/DeviceBridge.swift', '    static let remotePairingPort: UInt16 = 49_152', '''    static let defaultRemotePairingPort: UInt16 = 49_152
    static let remotePairingPortKey = "WaypointTest.remotePairingPort"

    static var remotePairingPort: UInt16 {
        let saved = UserDefaults.standard.integer(forKey: remotePairingPortKey)
        guard let port = UInt16(exactly: saved), port > 0 else { return defaultRemotePairingPort }
        return port
    }''')
edit('Waypoint/Services/DeviceBridge.swift',
     '        address.sin_port = in_port_t(Self.remotePairingPort).bigEndian',
     '''        let port = Self.remotePairingPort
        address.sin_port = in_port_t(port).bigEndian
        NSLog("[WaypointTest] connecting to developer service port=%d", Int(port))''')
edit('Waypoint/Views/SetupView.swift',
     '    @State private var isSideStoreConfirmationPresented = false',
     '''    @State private var isSideStoreConfirmationPresented = false
    @State private var servicePortText = String(DeviceBridge.remotePairingPort)

    private var enteredServicePort: UInt16? {
        guard let port = UInt16(servicePortText.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0 else { return nil }
        return port
    }''')
edit('Waypoint/Views/SetupView.swift',
     '''            Section {
                Toggle(
                    "Notify If Spoof Stops",''',
     '''            Section {
                TextField("Developer service port", text: $servicePortText)
                    .keyboardType(.numberPad)
                    .accessibilityLabel("Developer service port")
                Button("Save Port") {
                    guard let port = enteredServicePort else { return }
                    UserDefaults.standard.set(Int(port), forKey: DeviceBridge.remotePairingPortKey)
                    servicePortText = String(port)
                }
                .disabled(enteredServicePort == nil || enteredServicePort == DeviceBridge.remotePairingPort)
            } header: {
                Text("Developer Connection")
            } footer: {
                Text("Default: 49152. A saved port is used the next time Waypoint connects.")
            }

            Section {
                Toggle(
                    "Notify If Spoof Stops",''')
edit('Waypoint/Services/DeviceBridge.swift', '''                    fallback: "The device rejected the simulated location."
                )''', '''                    fallback: "The device rejected the simulated location."
                )
                let defaults = UserDefaults.standard
                let count = defaults.integer(forKey: "WaypointTest.nativeWriteCount") + 1
                defaults.set(Date().timeIntervalSince1970, forKey: "WaypointTest.nativeLastWrite")
                defaults.set("", forKey: "WaypointTest.nativeError")
                defaults.set(count, forKey: "WaypointTest.nativeWriteCount")
                NSLog("[WaypointTest] native write succeeded count=%d", count)''')
edit('Waypoint/Services/DeviceBridge.swift', '''        idevice_error_free(ffiError)
        throw DeviceBridgeError.ffi(code: code, message: message)''', '''        idevice_error_free(ffiError)
        let detail = "Native error \\(code): \\(message)"
        UserDefaults.standard.set(String(detail.prefix(300)), forKey: "WaypointTest.nativeError")
        NSLog("[WaypointTest] native failure code=%d stage=%@", code, fallback)
        throw DeviceBridgeError.ffi(code: code, message: message)''')
edit('Waypoint/Views/MapSpoofView.swift', '    @EnvironmentObject var model: AppModel', '''    @EnvironmentObject var model: AppModel
    @AppStorage("WaypointTest.nativeWriteCount") var nativeWriteCount = 0
    @AppStorage("WaypointTest.nativeLastWrite") var nativeLastWrite = 0.0
    @AppStorage("WaypointTest.nativeError") var nativeError = ""''')
edit('Waypoint/Views/MapSpoofView+Controls.swift', '        VStack(spacing: 12) {', '''        VStack(spacing: 12) {
            if nativeWriteCount > 0 {
                Text("Written \\(nativeWriteCount) · \\(Date(timeIntervalSince1970: nativeLastWrite).formatted(date: .omitted, time: .standard))")
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !nativeError.isEmpty {
                Text(nativeError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }''')
edit('Waypoint/Services/CellularPathMonitor.swift', '    private var offlineSince: Date?', '''    private var offlineSince: Date?
    private var pathRevision: UInt64 = 0

    /// A revision changes only when physical reachability changes. A write is
    /// verified only if its entire round trip used one stable cellular state.
    func stableCellularRevision() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard hasCellularSample, hasWiFiSample,
              cellularIsSatisfied, !wifiIsSatisfied,
              let since = cellularOnlySince,
              Date().timeIntervalSince(since) >= 2 else { return nil }
        return pathRevision
    }''')
edit('Waypoint/Services/CellularPathMonitor.swift', '            self.update(cellular: path.status == .satisfied)', '''            NSLog("[WaypointTest] cellular path status=%@ usesCellular=%d usesWiFi=%d",
                  String(describing: path.status), path.usesInterfaceType(.cellular) ? 1 : 0,
                  path.usesInterfaceType(.wifi) ? 1 : 0)
            self.update(cellular: path.status == .satisfied)''')
edit('Waypoint/Services/CellularPathMonitor.swift', '            self.update(wifi: path.status == .satisfied)', '''            NSLog("[WaypointTest] WiFi path status=%@ usesCellular=%d usesWiFi=%d",
                  String(describing: path.status), path.usesInterfaceType(.cellular) ? 1 : 0,
                  path.usesInterfaceType(.wifi) ? 1 : 0)
            self.update(wifi: path.status == .satisfied)''')
edit('Waypoint/Services/CellularPathMonitor.swift', '''        if let cellular {
            hasCellularSample = true''', '''        if let cellular, !hasCellularSample || cellularIsSatisfied != cellular {
            pathRevision &+= 1
        }
        if let wifi, !hasWiFiSample || wifiIsSatisfied != wifi {
            pathRevision &+= 1
        }
        if let cellular {
            hasCellularSample = true''')
p=Path('Waypoint/App/AppModel+CellularHandoff.swift');s=p.read_text();s=s.replace('addingTimeInterval(8)','addingTimeInterval(20)').replace('addingTimeInterval(30)','addingTimeInterval(60)')
start=s.index('                for probe in 1...3 {')
end=s.index('                guard !Task.isCancelled,', start)
s=s[:start]+'''                let verificationDeadline = Date().addingTimeInterval(60)
                var verifiedWrites = 0
                while verifiedWrites < 3, Date() < verificationDeadline {
                    guard !Task.isCancelled,
                          cellularHandoffOperationID == operationID,
                          simulationSessionID == sessionID else { return }
                    guard let before = CellularPathMonitor.shared.stableCellularRevision() else {
                        verifiedWrites = 0
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    try await bridge.setLocation(coordinate)
                    SimulationNotificationMonitor.shared.recordHeartbeat(for: sessionID)
                    if CellularPathMonitor.shared.stableCellularRevision() == before {
                        verifiedWrites += 1
                        NSLog("[WaypointTest] cellular verified write %d of 3", verifiedWrites)
                    } else {
                        verifiedWrites = 0
                        NSLog("[WaypointTest] path changed during write; retaining session for bounded retry")
                    }
                    if verifiedWrites < 3 {
                        try await Task.sleep(for: .seconds(2))
                    }
                }
                guard verifiedWrites == 3 else {
                    cellularHandoffPathCheckFailed(
                        "Cellular did not stay stable for three successful writes within 60 seconds. The session is retained, but cellular operation is not confirmed.",
                        operationID: operationID,
                        sessionID: sessionID
                    )
                    return
                }
''' + s[end:];p.write_text(s)
print('Applied device port, successful native-write diagnostics, and bounded strict cellular verification.')

# This build links the matched header/library pair with native timeout support.
edit('Waypoint/Services/DeviceBridge.swift',
     '    private func connectSynchronously(pairingPath: String) throws {',
     '    private func connectSynchronously(pairingPath: String) throws {\n        idevice_set_global_timeout(5)\n        NSLog("[WaypointTest] native timeout patch v%u", locus_idevice_timeout_patch_version())')
edit('Waypoint/Services/DeviceBridge.swift',
     '            do {\n                try self.consume(\n                    location_simulation_set',
     '            do {\n                NSLog("[WaypointTest] native write started")\n                try self.consume(\n                    location_simulation_set')
edit('Waypoint/Services/DeviceBridge.swift',
     '        if let adapter {\n            adapter_free(adapter)',
     '        if let adapter {\n            if let error = adapter_close(adapter) { idevice_error_free(error) }\n            adapter_free(adapter)')
edit('Waypoint/App/AppModel+CellularHandoff.swift',
     'The retained spoof session stopped responding when mobile data returned. Turn Airplane Mode on and try the guided start again.',
     'The retained spoof session stopped responding when mobile data returned.\\n\\n\\(error.localizedDescription)')
