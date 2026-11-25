@preconcurrency import CoreBluetooth
import Foundation
import Observation
import LumaCore

/// Owns the CBCentralManager, every added light, scanning, persistence and the command pipeline.
///
/// Everything runs on the main actor: the central is created with `queue: .main`, so delegate
/// callbacks arrive on the main thread and hop in with `MainActor.assumeIsolated`.
@MainActor @Observable
final class LightManager: NSObject {
    static let shared = LightManager()

    private(set) var bluetoothState: CBManagerState = .unknown
    private(set) var lights: [Light] = []
    private(set) var nearby: [UUID: NearbyDevice] = [:]
    private(set) var isScanning = false
    private(set) var log: [LogEntry] = []
    private(set) var groups: [LightGroup] { didSet { saveGroups() } }
    var colorCorrection: Bool { didSet { UserDefaults.standard.set(colorCorrection, forKey: Keys.colorCorrection) } }

    /// Lights that are connected, sorted as shown.
    var readyLights: [Light] { lights.filter(\.isReady) }

    /// Compatible devices that haven't been added yet.
    var newCompatibleDevices: [NearbyDevice] {
        nearby.values
            .filter { $0.looksCompatible && light(for: $0.id) == nil }
            .sorted { $0.rssi > $1.rssi }
    }

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var scanStopTask: Task<Void, Never>?
    @ObservationIgnored private var dumpTask: Task<Void, Never>?

    private enum Keys {
        static let lights = "lights.v1"
        static let groups = "groups.v1"
        /// Legacy global scenes; migrated into the All Lights group once.
        static let scenes = "scenes.v1"
        static let builtInPresetsRemoved = "builtInPresetsRemoved"
        static let colorCorrection = "colorCorrection"
    }

    /// Coalescing window for slider and color-wheel drags.
    private static let flushDelay: Duration = .milliseconds(60)

    private override init() {
        let defaults = UserDefaults.standard
        if var saved = Self.decode([LightGroup].self, from: defaults.data(forKey: Keys.groups)) {
            // One-time cleanup: earlier builds seeded every group with built-in presets.
            if !defaults.bool(forKey: Keys.builtInPresetsRemoved) {
                for i in saved.indices { saved[i].presets.removeAll(where: \.isFormerBuiltIn) }
                defaults.set(try? JSONEncoder().encode(saved), forKey: Keys.groups)
            }
            groups = saved
        } else {
            let legacy = Self.decode([LightScene].self, from: defaults.data(forKey: Keys.scenes))
            let migrated = [LightGroup.allLights(presets: Self.migratePresets(legacy))]
            defaults.set(try? JSONEncoder().encode(migrated), forKey: Keys.groups)
            groups = migrated
        }
        defaults.set(true, forKey: Keys.builtInPresetsRemoved)
        colorCorrection = defaults.object(forKey: Keys.colorCorrection) as? Bool ?? true
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Old global scenes → presets, keeping only the ones the user made (built-ins are gone).
    private static func migratePresets(_ legacy: [LightScene]?) -> [LightPreset] {
        (legacy ?? []).map { LightPreset($0) }.filter { !$0.isFormerBuiltIn }
    }

    // MARK: - Lights

    func light(for id: UUID) -> Light? {
        lights.first { $0.id == id }
    }

    func add(_ device: NearbyDevice) {
        guard light(for: device.id) == nil, let peripheral = peripherals[device.id] else { return }
        let light = Light(peripheral: peripheral, name: device.name ?? "Light \(lights.count + 1)", state: LightState())
        lights.append(light)
        save()
        connect(light)
    }

    func remove(_ light: Light) {
        central.cancelPeripheralConnection(light.peripheral)
        lights.removeAll { $0.id == light.id }
        save()
        for index in groups.indices where groups[index].lightIDs.contains(light.id) {
            groups[index].lightIDs.removeAll { $0 == light.id }
        }
    }

    func rename(_ light: Light, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        light.name = trimmed
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        lights.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func reconnect(_ light: Light) {
        central.cancelPeripheralConnection(light.peripheral)
        connect(light)
    }

    private func connect(_ light: Light) {
        guard bluetoothState == .poweredOn else { return }
        light.status = .connecting
        light.peripheral.delegate = self
        // Connection requests never time out: if the light is out of range or powered off,
        // iOS connects as soon as it shows up again.
        central.connect(light.peripheral)
    }

    // MARK: - Groups & presets

    func group(id: UUID) -> LightGroup? {
        groups.first { $0.id == id }
    }

    /// Every member, whatever its connection status, in `lights` order.
    func lights(in group: LightGroup) -> [Light] {
        let ids = Set(group.memberIDs(allLightIDs: lights.map(\.id)))
        return lights.filter { ids.contains($0.id) }
    }

    /// Connected members only.
    func readyLights(in group: LightGroup) -> [Light] {
        lights(in: group).filter(\.isReady)
    }

    @discardableResult
    func createGroup(named name: String, lightIDs: [UUID]) -> LightGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = LightGroup(name: trimmed.isEmpty ? "Group \(groups.count + 1)" : trimmed, lightIDs: lightIDs)
        groups.append(group)
        return group
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groupIndex(id) else { return }
        groups[index].name = trimmed
    }

    func setMembers(of id: UUID, to lightIDs: [UUID]) {
        guard let index = groupIndex(id), !groups[index].includesAllLights else { return }
        groups[index].lightIDs = lightIDs
    }

    func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        groups.move(fromOffsets: source, toOffset: destination)
    }

    /// Saves each connected member's current look (so one preset can hold different colors).
    func savePreset(named name: String, in groupID: UUID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groupIndex(groupID) else { return }
        let looks = readyLights(in: groups[index]).map { ($0.id, $0.state) }
        guard !looks.isEmpty else { return }
        groups[index].presets.append(LightPreset(name: trimmed, capturing: looks))
    }

    /// Whether the group's connected lights currently look exactly like the preset.
    func isActive(_ preset: LightPreset, in group: LightGroup) -> Bool {
        preset.matches(readyLights(in: group).map { ($0.id, $0.state) })
    }

    func renamePreset(_ presetID: UUID, in groupID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groupIndex(groupID),
              let presetIndex = groups[index].presets.firstIndex(where: { $0.id == presetID }) else { return }
        groups[index].presets[presetIndex].name = trimmed
    }

    /// Re-captures a preset from the lights' current looks, keeping its name and position.
    func updatePreset(_ presetID: UUID, in groupID: UUID) {
        guard let index = groupIndex(groupID),
              let presetIndex = groups[index].presets.firstIndex(where: { $0.id == presetID }) else { return }
        let looks = readyLights(in: groups[index]).map { ($0.id, $0.state) }
        guard !looks.isEmpty else { return }
        let old = groups[index].presets[presetIndex]
        groups[index].presets[presetIndex] = LightPreset(id: old.id, name: old.name, capturing: looks)
    }

    func deletePreset(_ presetID: UUID, in groupID: UUID) {
        guard let index = groupIndex(groupID) else { return }
        groups[index].presets.removeAll { $0.id == presetID }
    }

    func movePresets(in groupID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = groupIndex(groupID) else { return }
        groups[index].presets.move(fromOffsets: source, toOffset: destination)
    }

    func applyPreset(_ preset: LightPreset, in groupID: UUID) {
        guard let group = group(id: groupID) else { return }
        for light in readyLights(in: group) {
            apply(preset.state(for: light.id), to: [light])
        }
    }

    private func groupIndex(_ id: UUID) -> Int? {
        groups.firstIndex { $0.id == id }
    }

    // MARK: - Scanning

    func startScan(duration: Duration = .seconds(15)) {
        guard bluetoothState == .poweredOn else { return }
        // No service filter: a light with a slightly different firmware should still show up
        // in Diagnostics rather than silently not appearing.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        scanStopTask?.cancel()
        scanStopTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.stopScan()
        }
    }

    func stopScan() {
        scanStopTask?.cancel()
        if central.isScanning { central.stopScan() }
        isScanning = false
    }

    // MARK: - Control

    // Coalescing keys. Color, white and effect share one key: only the latest look matters.
    private enum Key { static let power: UInt8 = 0x11, brightness: UInt8 = 0x13, look: UInt8 = 0x15 }

    func setPower(_ on: Bool, for targets: [Light]) {
        for light in targets {
            light.state.isOn = on
            enqueue(light.encoder(colorCorrection: colorCorrection).power(on), key: Key.power, to: light)
        }
    }

    func setBrightness(_ percent: Int, for targets: [Light]) {
        for light in targets {
            light.state.brightness = percent
            // Changing brightness on a light that's off turns it on, like a real dimmer.
            if !light.state.isOn { setPower(true, for: [light]) }
            enqueue(light.encoder(colorCorrection: colorCorrection).brightness(percent), key: Key.brightness, to: light)
        }
    }

    func setColor(_ color: RGB, for targets: [Light]) {
        for light in targets {
            light.state.mode = .color(color)
            if !light.state.isOn { setPower(true, for: [light]) }
            enqueue(light.encoder(colorCorrection: colorCorrection).color(color), key: Key.look, to: light)
        }
    }

    func setWhite(warmth: Double, for targets: [Light]) {
        for light in targets {
            light.state.mode = .white(warmth)
            if !light.state.isOn { setPower(true, for: [light]) }
            enqueue(light.encoder(colorCorrection: colorCorrection).white(warmth: warmth), key: Key.look, to: light)
        }
    }

    func setEffect(_ effect: Effect, for targets: [Light]) {
        for light in targets {
            guard let frames = light.encoder(colorCorrection: colorCorrection).effect(effect) else { continue }
            light.state.mode = .effect(effect)
            if !light.state.isOn { setPower(true, for: [light]) }
            enqueue(frames, key: Key.look, to: light)
        }
    }

    func apply(_ state: LightState, to targets: [Light]) {
        for light in targets {
            light.state = state
            // Drop queued slider updates so they can't land after (and override) the scene.
            light.flushTask?.cancel()
            light.flushTask = nil
            _ = light.outbox.drain()
            for frame in light.encoder(colorCorrection: colorCorrection).frames(for: state) {
                write(frame, to: light)
            }
        }
        save()
    }

    /// Diagnostics: send arbitrary bytes, unmodified.
    func sendRaw(_ bytes: [UInt8], to light: Light) {
        write(bytes, to: light)
    }

    private func enqueue(_ frames: [[UInt8]], key: UInt8, to light: Light) {
        light.outbox.enqueue(frames, for: key)
        guard light.flushTask == nil else { return }
        light.flushTask = Task { [weak self, weak light] in
            try? await Task.sleep(for: Self.flushDelay)
            guard let self, let light else { return }
            light.flushTask = nil
            for frame in light.outbox.drain() {
                self.write(frame, to: light)
            }
            self.save()
        }
    }

    /// `beforeReady` lets the login frames through while the light is still authenticating.
    private func write(_ frame: [UInt8], to light: Light, beforeReady: Bool = false) {
        guard light.isReady || beforeReady, let characteristic = light.writeCharacteristic else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        light.peripheral.writeValue(Data(frame), for: characteristic, type: type)
        record(light.name, .sent, frame.hexString)
    }

    // MARK: - Persistence & log

    private func save() {
        let known = lights.map { KnownLight(id: $0.id, name: $0.name, state: $0.state) }
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(known), forKey: Keys.lights)
    }

    private func saveGroups() {
        UserDefaults.standard.set(try? JSONEncoder().encode(groups), forKey: Keys.groups)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func restoreKnownLights() {
        guard lights.isEmpty else {
            lights.forEach(connect)
            return
        }
        let known = Self.decode([KnownLight].self, from: UserDefaults.standard.data(forKey: Keys.lights)) ?? []
        let found = central.retrievePeripherals(withIdentifiers: known.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.identifier, $0) })
        for entry in known {
            guard let peripheral = byID[entry.id] else { continue }
            peripherals[entry.id] = peripheral
            let light = Light(peripheral: peripheral, name: entry.name, state: entry.state)
            lights.append(light)
            connect(light)
        }
        if lights.isEmpty { startScan() }
    }

    func clearLog() { log.removeAll() }

    private func record(_ light: String, _ direction: LogEntry.Direction, _ text: String) {
        log.append(LogEntry(date: .now, light: light, direction: direction, text: text))
        if log.count > 300 { log.removeFirst(log.count - 300) }
        scheduleDiagnosticsDump()
    }

    /// Writes Documents/diagnostics.txt (debounced). It can be pulled over USB with
    /// `afcclient --container XTL-<team>.com.example.LumaRemote get /Documents/diagnostics.txt`.
    private func scheduleDiagnosticsDump() {
        guard dumpTask == nil else { return }
        dumpTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.dumpTask = nil
            self.writeDiagnostics()
        }
    }

    private func writeDiagnostics() {
        let time = Date.now.formatted(date: .abbreviated, time: .standard)
        var out = ["Luma diagnostics, \(time)", "Bluetooth: \(bluetoothState.name)", "Color correction: \(colorCorrection)", ""]
        out.append("== Lights")
        for light in lights {
            out.append("\(light.name)  id=\(light.id.uuidString)  status=\(light.status)  state=\(light.state.summary)")
            if let c = light.writeCharacteristic { out.append("  write char \(c.uuid.uuidString) [\(c.properties.summary)]") }
            for service in light.gatt {
                out.append("  service \(service.id)")
                for c in service.characteristics { out.append("    char \(c.id) [\(c.properties)]") }
            }
        }
        out.append("")
        out.append("== Nearby (strongest first)")
        for d in nearby.values.sorted(by: { $0.rssi > $1.rssi }) {
            out.append("\(d.displayName)  rssi=\(d.rssi)  services=\(d.services.joined(separator: ","))  mfr=\(d.manufacturerData ?? "-")  id=\(d.id.uuidString)")
        }
        out.append("")
        out.append("== Log")
        for e in log {
            out.append("\(e.date.formatted(date: .omitted, time: .standard)) \(e.direction.rawValue) \(e.light): \(e.text)")
        }
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? out.joined(separator: "\n").write(to: dir.appending(path: "diagnostics.txt"), atomically: true, encoding: .utf8)
    }

    private func name(of peripheral: CBPeripheral) -> String {
        light(for: peripheral.identifier)?.name ?? peripheral.name ?? peripheral.identifier.uuidString
    }

    // MARK: - Delegate handlers (main actor)

    private func handleStateUpdate(_ state: CBManagerState) {
        bluetoothState = state
        if state == .poweredOn {
            restoreKnownLights()
        } else {
            isScanning = false
            lights.forEach { $0.status = .disconnected }
        }
    }

    private func handleDiscovery(_ peripheral: CBPeripheral, name: String?, services: [String], manufacturerData: String?, rssi: Int) {
        peripherals[peripheral.identifier] = peripheral
        var device = nearby[peripheral.identifier] ?? NearbyDevice(id: peripheral.identifier, name: nil, rssi: rssi, services: [], lastSeen: .now)
        device.name = name ?? peripheral.name ?? device.name
        device.rssi = rssi
        if !services.isEmpty { device.services = services }
        if let manufacturerData { device.manufacturerData = manufacturerData }
        scheduleDiagnosticsDump()
        device.lastSeen = .now
        nearby[peripheral.identifier] = device
    }

    private func handleConnected(_ peripheral: CBPeripheral) {
        guard let light = light(for: peripheral.identifier) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        light.status = .discovering
        light.gatt = []
        light.writeCharacteristic = nil
        light.notificationsOn = false
        light.loginTimeout?.cancel()
        record(light.name, .info, "Connected")
        peripheral.discoverServices(nil)
    }

    private func handleDisconnected(_ peripheral: CBPeripheral, error: String?, retryDelay: Duration? = nil) {
        guard let light = light(for: peripheral.identifier) else { return }
        record(light.name, .info, "Disconnected" + (error.map { ": \($0)" } ?? ""))
        light.status = .disconnected
        light.loginTimeout?.cancel()
        light.flushTask?.cancel()
        light.flushTask = nil
        _ = light.outbox.drain()
        guard let retryDelay else {
            connect(light) // a pending connect simply waits until the light is back in range
            return
        }
        // The light actively refused: back off instead of looping.
        Task { [weak self, weak light] in
            try? await Task.sleep(for: retryDelay)
            guard let self, let light, self.light(for: light.id) === light, light.status == .disconnected else { return }
            self.connect(light)
        }
    }

    private func handleServices(_ peripheral: CBPeripheral, error: String?) {
        guard let light = light(for: peripheral.identifier) else { return }
        let services = peripheral.services ?? []
        if let error { record(light.name, .info, "Service discovery failed: \(error)") }
        light.servicesAwaitingCharacteristics = services.count
        if services.isEmpty { finishSetup(light) }
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    private func handleCharacteristics(_ peripheral: CBPeripheral, service: CBService) {
        guard let light = light(for: peripheral.identifier) else { return }
        let characteristics = service.characteristics ?? []
        light.gatt.append(GATTService(
            id: service.uuid.uuidString,
            characteristics: characteristics.map { GATTCharacteristic(id: $0.uuid.uuidString, properties: $0.properties.summary) }
        ))
        if let model = DayBetter.modelUUIDs(forService: service.uuid.uuidString) {
            record(light.name, .info, "Control service \(model.service) (model \(model.model)): write \(model.write), notify \(model.notify)")
            for characteristic in characteristics {
                if characteristic.uuid == CBUUID(string: model.write) {
                    light.writeCharacteristic = characteristic
                } else if characteristic.uuid == CBUUID(string: model.notify),
                          characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
        light.servicesAwaitingCharacteristics -= 1
        if light.servicesAwaitingCharacteristics <= 0 { finishSetup(light) }
    }

    private func finishSetup(_ light: Light) {
        guard light.writeCharacteristic != nil else {
            light.status = .unsupported
            record(light.name, .info, "No DayBetter control service (E0xx with A0xx) found; this light uses a different protocol")
            return
        }
        light.status = .authenticating
        if light.notificationsOn { beginLogin(light) }
        // Otherwise beginLogin runs when notifications switch on (the challenge arrives there).
    }

    /// Sends the CCHIP hello. A light that answers is `.cchip`; one that stays silent for 2 s is an
    /// older strip-protocol light and is used without logging in.
    private func beginLogin(_ light: Light) {
        guard light.status == .authenticating else { return }
        record(light.name, .info, "Logging in")
        write(DayBetter.Login.hello(), to: light, beforeReady: true)
        light.loginTimeout?.cancel()
        light.loginTimeout = Task { [weak self, weak light] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let light, light.status == .authenticating else { return }
            self.record(light.name, .info, "No login challenge; using the strip protocol")
            light.variant = .strip
            self.becomeReady(light)
        }
    }

    private func becomeReady(_ light: Light) {
        light.loginTimeout?.cancel()
        light.status = .ready
        record(light.name, .info, "Ready (\(light.variant.rawValue) protocol)")
        // Ask for the real power state (the light may have been switched with its IR remote).
        write(light.encoder(colorCorrection: colorCorrection).status(), to: light)
    }

    private func handleNotificationState(_ peripheral: CBPeripheral, enabled: Bool, error: String?) {
        guard let light = light(for: peripheral.identifier) else { return }
        record(light.name, .info, "Notifications: " + (error.map { "failed (\($0))" } ?? (enabled ? "on" : "off")))
        light.notificationsOn = enabled
        if enabled, light.status == .authenticating { beginLogin(light) }
    }

    private func handleNotification(_ peripheral: CBPeripheral, bytes: [UInt8]) {
        guard let light = light(for: peripheral.identifier) else { return }
        record(light.name, .received, bytes.hexString)
        switch DayBetter.parse(bytes) {
        case .challenge(let challenge):
            light.variant = .cchip
            write(DayBetter.Login.answer(challenge: challenge), to: light, beforeReady: true)
        case .login(let accepted):
            if accepted {
                becomeReady(light)
            } else {
                light.loginTimeout?.cancel()
                light.status = .unsupported
                record(light.name, .info, "Login rejected")
            }
        case .status(let isOn, let brightness):
            light.state.isOn = isOn
            if let brightness, (1...100).contains(brightness) { light.state.brightness = brightness }
        case .ack, .unknown:
            break
        }
    }
}

// MARK: - CoreBluetooth delegates

extension LightManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated { handleStateUpdate(state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        let manufacturerData = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0).hexString }
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            handleDiscovery(peripheral, name: name, services: services, manufacturerData: manufacturerData, rssi: rssi)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { handleConnected(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated { handleDisconnected(peripheral, error: message, retryDelay: .seconds(3)) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated { handleDisconnected(peripheral, error: message) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated { handleServices(peripheral, error: message) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { handleCharacteristics(peripheral, service: service) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        MainActor.assumeIsolated { handleNotification(peripheral, bytes: bytes) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let enabled = characteristic.isNotifying
        let message = error?.localizedDescription
        MainActor.assumeIsolated { handleNotificationState(peripheral, enabled: enabled, error: message) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let message = error?.localizedDescription else { return }
        MainActor.assumeIsolated {
            record(name(of: peripheral), .info, "Write failed: \(message)")
        }
    }
}

extension CBCharacteristicProperties {
    var summary: String {
        let names: [(CBCharacteristicProperties, String)] = [
            (.read, "read"), (.write, "write"), (.writeWithoutResponse, "writeNoResp"),
            (.notify, "notify"), (.indicate, "indicate"),
        ]
        let present = names.filter { contains($0.0) }.map(\.1)
        return present.isEmpty ? "—" : present.joined(separator: ", ")
    }
}
