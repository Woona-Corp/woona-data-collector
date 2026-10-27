import Foundation

@MainActor
final class BleSessionManager {
    private let centralClient: BleCentralClient
    private let serviceUUID: UUID
    private let characteristicUUID: UUID
    private let scanTimeoutMillis: UInt64?
    private let onDeviceFound: @MainActor (BleDevice) -> Void
    private let notificationSink: BleNotificationSink
    private let onDiagnosticMessage: @MainActor (String) -> Void
    private let onPreviewReady: @MainActor () -> Void
    private let onCaptureReady: @MainActor () -> Void
    private let onStateChanged: @MainActor (BleSessionState) -> Void
    private let onError: @MainActor (String, Error?) -> Void

    private var discoveredDevicesByID: [UUID: BleDevice] = [:]
    private var discoveredDeviceOrder: [UUID] = []
    private var activePeripheralIdentifier: UUID?
    private var purpose = BleConnectionPurpose.record
    private var connectionToken = UUID()
    private var previewReady = false
    private var disconnecting = false
    private var failureDisconnectIdentifiers: Set<UUID> = []
    private var pendingScanUseServiceFilter: Bool?
    private var scanTimeoutTask: Task<Void, Never>?
    private var sessionState: BleSessionState = .idle
    private let transportProfile: BleTransportProfile = .iosManaged

    init(
        centralClient: BleCentralClient = CoreBluetoothBleCentralClient(),
        serviceUUID: UUID = BleConstants.serviceUUID,
        characteristicUUID: UUID = BleConstants.notificationCharacteristicUUID,
        scanTimeoutMillis: UInt64? = 10_000,
        onDeviceFound: @escaping @MainActor (BleDevice) -> Void,
        onPacketReceived: @escaping @Sendable (Data) -> Void,
        onDiagnosticMessage: @escaping @MainActor (String) -> Void,
        onCaptureReady: @escaping @MainActor () -> Void,
        onStateChanged: @escaping @MainActor (BleSessionState) -> Void,
        onError: @escaping @MainActor (String, Error?) -> Void,
        onPreviewReady: @escaping @MainActor () -> Void = {},
        onPreviewBytes: @escaping @Sendable (Data) -> Void = { _ in }
    ) {
        self.centralClient = centralClient
        self.serviceUUID = serviceUUID
        self.characteristicUUID = characteristicUUID
        self.scanTimeoutMillis = scanTimeoutMillis
        self.onDeviceFound = onDeviceFound
        self.onDiagnosticMessage = onDiagnosticMessage
        self.onCaptureReady = onCaptureReady
        self.onPreviewReady = onPreviewReady
        self.onStateChanged = onStateChanged
        self.onError = onError
        self.notificationSink = BleNotificationSink(
            expectedCharacteristicUUID: characteristicUUID,
            onPacketReceived: onPacketReceived,
            onPreviewBytes: onPreviewBytes,
            onDiagnosticMessage: { message in
                Task { @MainActor in
                    onDiagnosticMessage(message)
                }
            }
        )
        self.centralClient.delegate = self
    }

    func currentState() -> BleSessionState {
        sessionState
    }

    func currentTransportProfile() -> BleTransportProfile {
        transportProfile
    }

    func discoveredDevices() -> [BleDevice] {
        discoveredDeviceOrder.compactMap { discoveredDevicesByID[$0] }
    }

    func currentPeripheralIdentifier() -> UUID? {
        activePeripheralIdentifier
    }

    func startScanning(useServiceFilter: Bool = true) {
        guard validateBluetoothAuthorization() else { return }
        guard activePeripheralIdentifier == nil else {
            onDiagnosticMessage("Disconnect before scanning for another BLE device")
            return
        }

        switch centralClient.powerState {
        case .poweredOn:
            beginScanning(useServiceFilter: useServiceFilter)
        case .unknown, .resetting:
            pendingScanUseServiceFilter = useServiceFilter
            transition(.scanStarted)
            onDiagnosticMessage("Waiting for Bluetooth to become ready")
        case .poweredOff:
            fail("Bluetooth is off")
        case .unauthorized:
            fail("Bluetooth permission denied")
        case .unsupported:
            fail("Bluetooth is unsupported on this device")
        }
    }

    func stopScanning() {
        pendingScanUseServiceFilter = nil
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        centralClient.stopScanning()
        transition(.scanStopped)
    }

    @discardableResult
    func connect(
        to identifier: UUID,
        purpose: BleConnectionPurpose = .record,
        prepareForCapture: () async -> Void = {}
    ) async -> Bool {
        guard validateBluetoothReady() else { return false }
        guard activePeripheralIdentifier == nil else {
            onDiagnosticMessage("BLE connection already in progress")
            return false
        }
        guard discoveredDevicesByID[identifier] != nil else {
            transition(.failure)
            onError("BLE device not found: \(identifier.uuidString)", nil)
            return false
        }

        stopScanning()
        failureDisconnectIdentifiers.remove(identifier)
        activePeripheralIdentifier = identifier
        self.purpose = purpose
        connectionToken = UUID(); previewReady = false; disconnecting = false
        notificationSink.prepareForConnection(identifier: identifier, purpose: purpose)
        transition(.connectRequested)
        if purpose == .record { await prepareForCapture() }

        guard activePeripheralIdentifier == identifier else { return false }

        onDiagnosticMessage("BLE transport: \(transportProfile.title). iOS manages connection priority, MTU, and PHY automatically.")
        centralClient.connect(to: identifier)
        return true
    }

    func disconnect() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil

        guard let activePeripheralIdentifier else {
            transition(.disconnected)
            return
        }

        centralClient.cancelControlWrites(for: activePeripheralIdentifier)
        previewReady = false
        centralClient.disconnect(from: activePeripheralIdentifier)
        if purpose == .v2Preview {
            // Do not reconnect the same CBPeripheral until its terminal callback;
            // old CCC/write callbacks must not initialize the next protocol run.
            disconnecting = true
            notificationSink.deactivate(identifier: activePeripheralIdentifier)
        } else {
            clearActivePeripheral(identifier: activePeripheralIdentifier)
            transition(.disconnected)
        }
    }

    func writePreviewFrame(_ data: Data, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard purpose == .v2Preview, previewReady, !disconnecting, let identifier = activePeripheralIdentifier else {
            completion(.failure(BleControlWriteError.disconnected)); return
        }
        let token = connectionToken
        centralClient.writeControlFrame(data, characteristicUUID: BleConstants.controlCharacteristicUUID, for: identifier) { [weak self] result in
            Task { @MainActor in
                guard let self, self.connectionToken == token,
                      self.activePeripheralIdentifier == identifier, !self.disconnecting else { return }
                completion(result)
            }
        }
    }

    func close() {
        stopScanning()
        disconnect()
    }

    private func beginScanning(useServiceFilter: Bool) {
        pendingScanUseServiceFilter = nil
        discoveredDevicesByID.removeAll(keepingCapacity: true)
        discoveredDeviceOrder.removeAll(keepingCapacity: true)
        centralClient.startScanning(serviceUUIDs: useServiceFilter ? [serviceUUID] : nil)
        transition(.scanStarted)
        scheduleScanTimeout()
    }

    private func validateBluetoothAuthorization() -> Bool {
        switch centralClient.authorization {
        case .denied, .restricted:
            fail("Bluetooth permission denied")
            return false
        case .allowed, .notDetermined:
            return true
        }
    }

    private func validateBluetoothReady() -> Bool {
        guard validateBluetoothAuthorization() else { return false }

        switch centralClient.powerState {
        case .poweredOn:
            return true
        case .poweredOff:
            fail("Bluetooth is off")
            return false
        case .unauthorized:
            fail("Bluetooth permission denied")
            return false
        case .unsupported:
            fail("Bluetooth is unsupported on this device")
            return false
        case .unknown, .resetting:
            fail("Bluetooth is not ready")
            return false
        }
    }

    private func scheduleScanTimeout() {
        scanTimeoutTask?.cancel()
        guard let scanTimeoutMillis else { return }

        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: scanTimeoutMillis * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.stopScanning()
        }
    }

    private func transition(_ event: BleSessionEvent) {
        sessionState = BleSessionStateMachine.transition(currentState: sessionState, event: event)
        onStateChanged(sessionState)
    }

    private func remember(_ device: BleDevice) {
        if discoveredDevicesByID[device.id] == nil {
            discoveredDeviceOrder.append(device.id)
        }
        discoveredDevicesByID[device.id] = device
        onDeviceFound(device)
    }

    private func fail(_ message: String, error: Error? = nil) {
        pendingScanUseServiceFilter = nil
        if let activePeripheralIdentifier {
            if purpose == .v2Preview {
                // HELLO may already have changed firmware mode while SD status
                // remains unknown. An automatic cancel can stop an SD recording.
                // Disable protocol I/O and keep the link until explicit consent.
                previewReady = false
                centralClient.cancelControlWrites(for: activePeripheralIdentifier)
                notificationSink.deactivate(identifier: activePeripheralIdentifier)
            } else {
                failureDisconnectIdentifiers.insert(activePeripheralIdentifier)
                centralClient.disconnect(from: activePeripheralIdentifier)
                clearActivePeripheral(identifier: activePeripheralIdentifier)
            }
        }
        transition(.failure)
        onError(message, error)
    }

    private func clearActivePeripheral(identifier: UUID) {
        guard activePeripheralIdentifier == identifier else { return }
        activePeripheralIdentifier = nil
        connectionToken = UUID(); previewReady = false; disconnecting = false
        centralClient.cancelControlWrites(for: identifier)
        notificationSink.deactivate(identifier: identifier)
    }
}

extension BleSessionManager: BleCentralClientDelegate {
    nonisolated func centralClientDidUpdateState(_ client: BleCentralClient) {
        Task { @MainActor in
            if client.powerState == .poweredOn, let pendingScanUseServiceFilter {
                beginScanning(useServiceFilter: pendingScanUseServiceFilter)
            } else if client.powerState == .poweredOff {
                fail("Bluetooth is off")
            } else if client.powerState == .unauthorized || client.authorization == .denied || client.authorization == .restricted {
                fail("Bluetooth permission denied")
            }
        }
    }

    nonisolated func centralClient(_ client: BleCentralClient, didDiscover device: BleDevice) {
        Task { @MainActor in
            remember(device)
        }
    }

    nonisolated func centralClient(_ client: BleCentralClient, didConnect identifier: UUID) {
        Task { @MainActor in
            guard activePeripheralIdentifier == identifier, !disconnecting else { return }
            transition(.connected)
            centralClient.discoverServices([serviceUUID], for: identifier)
        }
    }

    nonisolated func centralClient(_ client: BleCentralClient, didFailToConnect identifier: UUID, error: Error?) {
        Task { @MainActor in
            guard activePeripheralIdentifier == identifier else { return }
            clearActivePeripheral(identifier: identifier)
            fail("BLE connection failed", error: error)
        }
    }

    nonisolated func centralClient(_ client: BleCentralClient, didDisconnect identifier: UUID, error: Error?) {
        Task { @MainActor in
            if failureDisconnectIdentifiers.remove(identifier) != nil {
                clearActivePeripheral(identifier: identifier)
                if let error {
                    onError("BLE disconnected with error", error)
                }
                return
            }

            guard activePeripheralIdentifier == identifier else { return }
            clearActivePeripheral(identifier: identifier)
            transition(.disconnected)
            if let error {
                onError("BLE disconnected with error", error)
            }
        }
    }

    nonisolated func centralClient(
        _ client: BleCentralClient,
        didDiscoverServicesFor identifier: UUID,
        serviceUUIDs: [UUID],
        error: Error?
    ) {
        Task { @MainActor in
            guard activePeripheralIdentifier == identifier else { return }
            guard error == nil else {
                fail("BLE service discovery failed", error: error)
                return
            }
            guard serviceUUIDs.contains(serviceUUID) else {
                fail("Required Woona BLE service is missing. Select the Woona sensor, not another Bluetooth device.")
                return
            }

            centralClient.discoverCharacteristics(purpose == .v2Preview ? [characteristicUUID, BleConstants.controlCharacteristicUUID] : [characteristicUUID], serviceUUID: serviceUUID, for: identifier)
        }
    }

    nonisolated func centralClient(
        _ client: BleCentralClient,
        didDiscoverCharacteristicsFor identifier: UUID,
        serviceUUID: UUID,
        characteristicUUIDs: [UUID],
        error: Error?
    ) {
        Task { @MainActor in
            guard activePeripheralIdentifier == identifier else { return }
            guard error == nil else {
                fail("BLE characteristic discovery failed", error: error)
                return
            }
            guard serviceUUID == self.serviceUUID, characteristicUUIDs.contains(characteristicUUID) else {
                fail("Required BLE notification characteristic is missing")
                return
            }

            guard purpose != .v2Preview || characteristicUUIDs.contains(BleConstants.controlCharacteristicUUID) else {
                fail("V2 preview requires the FFF2 control characteristic; reconnect in Record mode for a Legacy sensor")
                return
            }
            notificationSink.expectNotificationRegistration(identifier: identifier)
            centralClient.setNotifyValue(true, characteristicUUID: characteristicUUID, for: identifier)
        }
    }

    nonisolated func centralClient(
        _ client: BleCentralClient,
        didUpdateNotificationStateFor identifier: UUID,
        characteristicUUID: UUID,
        isNotifying: Bool,
        error: Error?
    ) {
        guard notificationSink.acceptsNotificationState(identifier: identifier, characteristicUUID: characteristicUUID) else { return }
        let isReady = error == nil
            && isNotifying
            && notificationSink.activate(identifier: identifier, characteristicUUID: characteristicUUID)

        Task { @MainActor in
            guard activePeripheralIdentifier == identifier else { return }
            guard isReady else {
                fail("Failed to enable BLE notifications", error: error)
                return
            }

            onDiagnosticMessage("BLE notifications enabled for \(characteristicUUID.uuidString)")
            onDiagnosticMessage("CoreBluetooth does not expose the negotiated connection interval; BLE timing summaries infer it from notification callback gaps.")
            guard !disconnecting else { return }
            if purpose == .v2Preview { previewReady = true; onPreviewReady() }
            else { onCaptureReady() }
        }
    }

    nonisolated func centralClient(
        _ client: BleCentralClient,
        didReceiveNotificationData data: Data,
        identifier: UUID,
        characteristicUUID: UUID
    ) {
        notificationSink.receive(data, identifier: identifier, characteristicUUID: characteristicUUID)
    }

    nonisolated func centralClient(
        _ client: BleCentralClient,
        didReceiveNotificationError error: Error,
        identifier: UUID,
        characteristicUUID: UUID
    ) {
        Task { @MainActor in
            guard activePeripheralIdentifier == identifier else { return }
            onDiagnosticMessage("BLE notification update failed for \(characteristicUUID.uuidString): \(error.localizedDescription)")
        }
    }
}

private final class BleNotificationSink: @unchecked Sendable {
    private let expectedCharacteristicUUID: UUID
    private let onPacketReceived: @Sendable (Data) -> Void
    private let onPreviewBytes: @Sendable (Data) -> Void
    private let onDiagnosticMessage: (String) -> Void
    private let lock = NSLock()

    private var purpose = BleConnectionPurpose.record
    private var registrationExpected = false
    private var expectedIdentifier: UUID?
    private var activeIdentifier: UUID?
    private var activeCharacteristicUUID: UUID?
    private var notificationCount: UInt64 = 0
    private var notificationGapSamples: UInt64 = 0
    private var notificationGapTotalMillis: UInt64 = 0
    private var notificationGapMaxMillis: UInt64 = 0
    private var notificationGapBucketCounts = Array(repeating: UInt64(0), count: notificationGapBucketLabels.count)
    private var longNotificationGapCount: UInt64 = 0
    private var rawBytesReceived: UInt64 = 0
    private var minNotificationBytes: Int?
    private var maxNotificationBytes: Int?
    private var lastNotificationMillis: UInt64?
    private var lastSummaryMillis: UInt64?
    private var lastLongGapDiagnosticMillis: UInt64 = 0

    init(
        expectedCharacteristicUUID: UUID,
        onPacketReceived: @escaping @Sendable (Data) -> Void,
        onPreviewBytes: @escaping @Sendable (Data) -> Void,
        onDiagnosticMessage: @escaping (String) -> Void
    ) {
        self.expectedCharacteristicUUID = expectedCharacteristicUUID
        self.onPacketReceived = onPacketReceived
        self.onPreviewBytes = onPreviewBytes
        self.onDiagnosticMessage = onDiagnosticMessage
    }

    func prepareForConnection(identifier: UUID, purpose: BleConnectionPurpose) {
        lock.withLock {
            expectedIdentifier = identifier
            self.purpose = purpose; registrationExpected = false
            activeIdentifier = nil
            activeCharacteristicUUID = nil
            resetTelemetryLocked(nowMillis: nil)
        }
    }

    func expectNotificationRegistration(identifier: UUID) {
        lock.withLock { if expectedIdentifier == identifier { registrationExpected = true } }
    }

    func acceptsNotificationState(identifier: UUID, characteristicUUID: UUID) -> Bool {
        lock.withLock {
            expectedIdentifier == identifier && expectedCharacteristicUUID == characteristicUUID &&
                (purpose == .record || registrationExpected)
        }
    }

    func activate(identifier: UUID, characteristicUUID: UUID) -> Bool {
        lock.withLock {
            guard expectedIdentifier == identifier, expectedCharacteristicUUID == characteristicUUID,
                  purpose == .record || registrationExpected else {
                return false
            }
            activeIdentifier = identifier
            activeCharacteristicUUID = expectedCharacteristicUUID
            resetTelemetryLocked(nowMillis: Self.currentMillis())
            return true
        }
    }

    func deactivate(identifier: UUID) {
        lock.withLock {
            guard expectedIdentifier == identifier || activeIdentifier == identifier else { return }
            expectedIdentifier = nil
            if activeIdentifier == identifier {
                activeIdentifier = nil
                activeCharacteristicUUID = nil
            }
            resetTelemetryLocked(nowMillis: nil)
        }
    }

    func receive(_ data: Data, identifier: UUID, characteristicUUID: UUID) {
        let nowMillis = Self.currentMillis()
        let (shouldForward, preview, diagnostics) = lock.withLock {
            guard activeIdentifier == identifier, activeCharacteristicUUID == characteristicUUID else {
                return (false, false, [String]())
            }
            return (true, purpose == .v2Preview, recordNotificationLocked(byteCount: data.count, nowMillis: nowMillis))
        }

        guard shouldForward else { return }
        if preview { onPreviewBytes(data) } else { onPacketReceived(data) }
        for diagnostic in diagnostics {
            onDiagnosticMessage(diagnostic)
        }
    }

    private func resetTelemetryLocked(nowMillis: UInt64?) {
        notificationCount = 0
        notificationGapSamples = 0
        notificationGapTotalMillis = 0
        notificationGapMaxMillis = 0
        notificationGapBucketCounts = Array(repeating: UInt64(0), count: Self.notificationGapBucketLabels.count)
        longNotificationGapCount = 0
        rawBytesReceived = 0
        minNotificationBytes = nil
        maxNotificationBytes = nil
        lastNotificationMillis = nil
        lastSummaryMillis = nowMillis
        lastLongGapDiagnosticMillis = 0
    }

    private func recordNotificationLocked(byteCount: Int, nowMillis: UInt64) -> [String] {
        var diagnostics: [String] = []
        notificationCount += 1
        rawBytesReceived += UInt64(byteCount)
        minNotificationBytes = min(minNotificationBytes ?? byteCount, byteCount)
        maxNotificationBytes = max(maxNotificationBytes ?? byteCount, byteCount)

        if let lastNotificationMillis {
            let gapMillis = nowMillis >= lastNotificationMillis ? nowMillis - lastNotificationMillis : 0
            notificationGapSamples += 1
            notificationGapTotalMillis += gapMillis
            notificationGapMaxMillis = max(notificationGapMaxMillis, gapMillis)
            recordNotificationGapBucketLocked(gapMillis)

            if gapMillis >= Self.longGapThresholdMillis {
                longNotificationGapCount += 1
                if nowMillis >= lastLongGapDiagnosticMillis + Self.longGapDiagnosticCooldownMillis {
                    lastLongGapDiagnosticMillis = nowMillis
                    diagnostics.append(
                        "BLE notification gap: gap=\(gapMillis)ms threshold=\(Self.longGapThresholdMillis)ms notifications=\(notificationCount)"
                    )
                }
            }
        }
        lastNotificationMillis = nowMillis

        if let lastSummaryMillis, nowMillis >= lastSummaryMillis + Self.summaryIntervalMillis {
            self.lastSummaryMillis = nowMillis
            diagnostics.append(buildSummaryLocked())
        }

        return diagnostics
    }

    private func buildSummaryLocked() -> String {
        let averageGapMillis = notificationGapSamples == 0
            ? "?"
            : String(format: "%.2f", Double(notificationGapTotalMillis) / Double(notificationGapSamples))
        let minBytes = minNotificationBytes.map(String.init) ?? "?"
        let maxBytes = maxNotificationBytes.map(String.init) ?? "?"
        let gapBuckets = notificationGapBucketCounts.enumerated()
            .map { index, count in "\(Self.notificationGapBucketLabels[index]):\(count)" }
            .joined(separator: ",")
        let inferredConnectionInterval = inferConnectionIntervalBucketLocked()

        return "BLE transport summary: notifications=\(notificationCount), rawBytes=\(rawBytesReceived), notifGapAvg=\(averageGapMillis)ms, notifGapMax=\(notificationGapMaxMillis)ms, notifGapLong=\(longNotificationGapCount), inferredConnIntervalFromCallbacks=\(inferredConnectionInterval), notifGapBucketsMs=\(gapBuckets), notificationBytes=\(minBytes)-\(maxBytes)"
    }

    private func recordNotificationGapBucketLocked(_ gapMillis: UInt64) {
        let index: Int
        switch gapMillis {
        case 0..<5:
            index = 0
        case 5..<15:
            index = 1
        case 15..<25:
            index = 2
        case 25..<35:
            index = 3
        case 35..<60:
            index = 4
        case 60..<100:
            index = 5
        default:
            index = 6
        }
        notificationGapBucketCounts[index] += 1
    }

    private func inferConnectionIntervalBucketLocked() -> String {
        var bestIndex: Int?
        var bestCount: UInt64 = 0

        for index in Self.connectionIntervalCandidateBucketIndices {
            let count = notificationGapBucketCounts[index]
            if count > bestCount {
                bestIndex = index
                bestCount = count
            }
        }

        guard let bestIndex, bestCount > 0 else { return "?" }
        return "\(Self.notificationGapBucketLabels[bestIndex])ms"
    }

    private static func currentMillis() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000)
    }

    private static let summaryIntervalMillis: UInt64 = 5_000
    private static let longGapThresholdMillis: UInt64 = 100
    private static let longGapDiagnosticCooldownMillis: UInt64 = 5_000
    private static let notificationGapBucketLabels = ["0-4", "5-14", "15-24", "25-34", "35-59", "60-99", "100+"]
    private static let connectionIntervalCandidateBucketIndices = [1, 2, 3, 4, 5]
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
