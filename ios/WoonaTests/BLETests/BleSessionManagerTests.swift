import CoreBluetooth
import XCTest
@testable import Woona

@MainActor
final class BleSessionManagerTests: XCTestCase {
    func testStartScanningCanUseServiceFilterAndPublishesDiscoveredDevices() async {
        let client = FakeBleCentralClient()
        let harness = BleHarness(client: client)
        let deviceID = UUID()

        harness.manager.startScanning(useServiceFilter: true)
        client.emitDiscoveredDevice(BleDevice(id: deviceID, name: "Woona Sensor"))
        await Task.yield()

        XCTAssertEqual(client.scanRequests, [[BleConstants.serviceUUID]])
        XCTAssertEqual(harness.states, [.scanning])
        XCTAssertEqual(harness.devices, [BleDevice(id: deviceID, name: "Woona Sensor")])
        XCTAssertEqual(harness.manager.discoveredDevices(), [BleDevice(id: deviceID, name: "Woona Sensor")])
    }

    func testStartScanningCanUseUnfilteredDiscovery() {
        let client = FakeBleCentralClient()
        let harness = BleHarness(client: client)

        harness.manager.startScanning(useServiceFilter: false)

        XCTAssertEqual(client.scanRequests, [nil])
        XCTAssertEqual(harness.states, [.scanning])
    }

    func testStartScanningWaitsForBluetoothReadyState() async {
        let client = FakeBleCentralClient(powerState: .unknown)
        let harness = BleHarness(client: client)

        harness.manager.startScanning(useServiceFilter: false)

        XCTAssertTrue(client.scanRequests.isEmpty)
        XCTAssertEqual(harness.states, [.scanning])
        XCTAssertEqual(harness.diagnostics, ["Waiting for Bluetooth to become ready"])
        XCTAssertTrue(harness.errors.isEmpty)

        client.powerState = .poweredOn
        client.emitStateUpdated()
        await Task.yield()

        XCTAssertEqual(client.scanRequests, [nil])
        XCTAssertEqual(harness.states, [.scanning, .scanning])
    }

    func testPoweredOffStateShowsClearError() {
        let client = FakeBleCentralClient(powerState: .poweredOff)
        let harness = BleHarness(client: client)

        harness.manager.startScanning()

        XCTAssertTrue(client.scanRequests.isEmpty)
        XCTAssertEqual(harness.states, [.failed])
        XCTAssertEqual(harness.errors.map(\.message), ["Bluetooth is off"])
    }

    func testPermissionDeniedShowsClearError() {
        let client = FakeBleCentralClient(authorization: .denied)
        let harness = BleHarness(client: client)

        harness.manager.startScanning()

        XCTAssertTrue(client.scanRequests.isEmpty)
        XCTAssertEqual(harness.states, [.failed])
        XCTAssertEqual(harness.errors.map(\.message), ["Bluetooth permission denied"])
    }

    func testConnectDiscoversServiceCharacteristicAndEnablesNotifications() async {
        let client = FakeBleCentralClient()
        let harness = BleHarness(client: client)
        let deviceID = UUID()

        harness.manager.startScanning()
        client.emitDiscoveredDevice(BleDevice(id: deviceID, name: "Woona Sensor"))
        await Task.yield()
        await harness.manager.connect(to: deviceID)
        client.emitConnected(deviceID)
        await Task.yield()
        client.emitServices(deviceID, serviceUUIDs: [BleConstants.serviceUUID])
        await Task.yield()
        client.emitCharacteristics(
            deviceID,
            serviceUUID: BleConstants.serviceUUID,
            characteristicUUIDs: [BleConstants.notificationCharacteristicUUID]
        )
        await Task.yield()
        client.emitNotificationState(
            deviceID,
            characteristicUUID: BleConstants.notificationCharacteristicUUID,
            isNotifying: true
        )
        await Task.yield()

        XCTAssertEqual(client.stopScanCount, 1)
        XCTAssertEqual(client.connectedIdentifiers, [deviceID])
        XCTAssertEqual(client.discoveredServices, [ServiceDiscoveryRequest(identifier: deviceID, serviceUUIDs: [BleConstants.serviceUUID])])
        XCTAssertEqual(
            client.discoveredCharacteristics,
            [
                CharacteristicDiscoveryRequest(
                    identifier: deviceID,
                    serviceUUID: BleConstants.serviceUUID,
                    characteristicUUIDs: [BleConstants.notificationCharacteristicUUID]
                )
            ]
        )
        XCTAssertEqual(
            client.notifyRequests,
            [NotifyRequest(identifier: deviceID, characteristicUUID: BleConstants.notificationCharacteristicUUID, enabled: true)]
        )
        XCTAssertEqual(harness.states, [.scanning, .idle, .connecting, .connected])
        XCTAssertEqual(harness.captureReadyCount, 1)
    }

    func testNotificationsReachCaptureUnchanged() async {
        let client = FakeBleCentralClient()
        let harness = BleHarness(client: client)
        let deviceID = UUID()
        let packetFragment = Data([0x33, 0x99, 0xAA, 0x55, 0x01, 0x02])

        harness.manager.startScanning()
        client.emitDiscoveredDevice(BleDevice(id: deviceID, name: "Woona Sensor"))
        await Task.yield()
        await harness.manager.connect(to: deviceID)
        client.emitConnected(deviceID)
        await Task.yield()
        client.emitNotificationData(
            packetFragment,
            identifier: deviceID,
            characteristicUUID: BleConstants.notificationCharacteristicUUID
        )
        await Task.yield()

        XCTAssertTrue(harness.packetFragments.isEmpty)

        client.emitServices(deviceID, serviceUUIDs: [BleConstants.serviceUUID])
        await Task.yield()
        client.emitCharacteristics(
            deviceID,
            serviceUUID: BleConstants.serviceUUID,
            characteristicUUIDs: [BleConstants.notificationCharacteristicUUID]
        )
        await Task.yield()
        client.emitNotificationState(
            deviceID,
            characteristicUUID: BleConstants.notificationCharacteristicUUID,
            isNotifying: true
        )
        client.emitNotificationData(
            packetFragment,
            identifier: deviceID,
            characteristicUUID: BleConstants.notificationCharacteristicUUID
        )
        await Task.yield()

        XCTAssertEqual(harness.packetFragments, [packetFragment])
    }

    func testDisconnectCleansUpPeripheralReference() async {
        let client = FakeBleCentralClient()
        let harness = BleHarness(client: client)
        let deviceID = UUID()

        harness.manager.startScanning()
        client.emitDiscoveredDevice(BleDevice(id: deviceID, name: "Woona Sensor"))
        await Task.yield()
        await harness.manager.connect(to: deviceID)
        client.emitConnected(deviceID)
        await Task.yield()

        XCTAssertEqual(harness.manager.currentPeripheralIdentifier(), deviceID)

        harness.manager.disconnect()

        XCTAssertEqual(client.disconnectedIdentifiers, [deviceID])
        XCTAssertNil(harness.manager.currentPeripheralIdentifier())
        XCTAssertEqual(harness.states.suffix(1), [.disconnected])
    }

    func testSecondConnectRequestIsIgnoredWhileConnectionIsActive() async {
        let client = FakeBleCentralClient()
        let harness = BleHarness(client: client)
        let firstDeviceID = UUID()
        let secondDeviceID = UUID()
        var rejectedPrepareCount = 0

        harness.manager.startScanning()
        client.emitDiscoveredDevice(BleDevice(id: firstDeviceID, name: "First"))
        client.emitDiscoveredDevice(BleDevice(id: secondDeviceID, name: "Second"))
        await Task.yield()

        await harness.manager.connect(to: firstDeviceID)
        await harness.manager.connect(to: secondDeviceID) {
            rejectedPrepareCount += 1
        }

        XCTAssertEqual(client.connectedIdentifiers, [firstDeviceID])
        XCTAssertEqual(rejectedPrepareCount, 0)
        XCTAssertEqual(harness.manager.currentPeripheralIdentifier(), firstDeviceID)
        XCTAssertEqual(harness.diagnostics.suffix(1), ["BLE connection already in progress"])
    }

    func testAcceptedConnectPreparesCaptureBeforeStartingCentralConnection() async {
        let client = FakeBleCentralClient()
        let harness = BleHarness(client: client)
        let deviceID = UUID()
        var didPrepareCapture = false

        harness.manager.startScanning()
        client.emitDiscoveredDevice(BleDevice(id: deviceID, name: "Woona Sensor"))
        await Task.yield()

        await harness.manager.connect(to: deviceID) {
            XCTAssertTrue(client.connectedIdentifiers.isEmpty)
            didPrepareCapture = true
        }

        XCTAssertTrue(didPrepareCapture)
        XCTAssertEqual(client.connectedIdentifiers, [deviceID])
        XCTAssertEqual(harness.manager.currentPeripheralIdentifier(), deviceID)
        XCTAssertEqual(harness.states.suffix(1), [.connecting])
    }

    func testStartScanningIsIgnoredWhileConnectionIsActive() async {
        let client = FakeBleCentralClient()
        let harness = BleHarness(client: client)
        let deviceID = UUID()

        harness.manager.startScanning()
        client.emitDiscoveredDevice(BleDevice(id: deviceID, name: "Woona Sensor"))
        await Task.yield()
        await harness.manager.connect(to: deviceID)
        client.emitConnected(deviceID)
        await Task.yield()

        harness.manager.startScanning(useServiceFilter: false)

        XCTAssertEqual(client.scanRequests.count, 1)
        XCTAssertEqual(harness.manager.currentPeripheralIdentifier(), deviceID)
        XCTAssertEqual(harness.states.suffix(1), [.connected])
        XCTAssertEqual(harness.diagnostics.suffix(1), ["Disconnect before scanning for another BLE device"])
    }

    func testConnectFailureAfterUserDisconnectIsIgnored() async {
        let client = FakeBleCentralClient()
        let harness = BleHarness(client: client)
        let deviceID = UUID()

        harness.manager.startScanning()
        client.emitDiscoveredDevice(BleDevice(id: deviceID, name: "Woona Sensor"))
        await Task.yield()
        await harness.manager.connect(to: deviceID)
        harness.manager.disconnect()

        client.emitFailedToConnect(deviceID)
        await Task.yield()

        XCTAssertEqual(client.disconnectedIdentifiers, [deviceID])
        XCTAssertNil(harness.manager.currentPeripheralIdentifier())
        XCTAssertEqual(harness.states.suffix(1), [.disconnected])
        XCTAssertTrue(harness.errors.isEmpty)
    }

    func testConnectCanBeRetriedAfterFailureWithoutRescan() async {
        let client = FakeBleCentralClient()
        let harness = BleHarness(client: client)
        let deviceID = UUID()

        harness.manager.startScanning()
        client.emitDiscoveredDevice(BleDevice(id: deviceID, name: "Woona Sensor"))
        await Task.yield()

        await harness.manager.connect(to: deviceID)
        client.emitFailedToConnect(deviceID, error: BleCentralClientError.peripheralReferenceMissing(deviceID))
        await Task.yield()

        await harness.manager.connect(to: deviceID)

        XCTAssertEqual(client.connectedIdentifiers, [deviceID, deviceID])
        XCTAssertEqual(harness.manager.currentPeripheralIdentifier(), deviceID)
        XCTAssertTrue(harness.states.contains(.failed))
        XCTAssertEqual(harness.states.suffix(1), [.connecting])
        XCTAssertEqual(harness.errors.map(\.message), ["BLE connection failed"])
    }

    func testNotificationErrorsAreLoggedAsDiagnostics() async {
        let client = FakeBleCentralClient()
        let harness = BleHarness(client: client)
        let deviceID = UUID()

        harness.manager.startScanning()
        client.emitDiscoveredDevice(BleDevice(id: deviceID, name: "Woona Sensor"))
        await Task.yield()
        await harness.manager.connect(to: deviceID)
        client.emitConnected(deviceID)
        await Task.yield()

        client.emitNotificationError(
            BleCentralClientError.characteristicReferenceMissing(
                identifier: deviceID,
                characteristicUUID: BleConstants.notificationCharacteristicUUID
            ),
            identifier: deviceID,
            characteristicUUID: BleConstants.notificationCharacteristicUUID
        )
        await Task.yield()

        XCTAssertTrue(harness.diagnostics.last?.contains("BLE notification update failed") == true)
    }

    func testSetupFailureDisconnectsActivePeripheral() async {
        let client = FakeBleCentralClient()
        let harness = BleHarness(client: client)
        let deviceID = UUID()

        harness.manager.startScanning()
        client.emitDiscoveredDevice(BleDevice(id: deviceID, name: "MacBook"))
        await Task.yield()
        await harness.manager.connect(to: deviceID)
        client.emitConnected(deviceID)
        await Task.yield()
        client.emitServices(deviceID, serviceUUIDs: [])
        await Task.yield()

        XCTAssertEqual(client.disconnectedIdentifiers, [deviceID])
        XCTAssertNil(harness.manager.currentPeripheralIdentifier())
        XCTAssertEqual(harness.states.suffix(1), [.failed])
        XCTAssertEqual(
            harness.errors.map(\.message),
            ["Required Woona BLE service is missing. Select the Woona sensor, not another Bluetooth device."]
        )

        client.emitDisconnected(deviceID)
        await Task.yield()

        XCTAssertEqual(harness.states.suffix(1), [.failed])
    }

    func testV2NotificationFailureKeepsThePhysicalLinkUntilExplicitDisconnect() async {
        let client = FakeBleCentralClient(); let harness = BleHarness(client: client); let identifier = UUID()
        client.emitDiscoveredDevice(.init(id: identifier, name: "V2 fixture")); await Task.yield()
        await harness.manager.connect(to: identifier, purpose: .v2Preview)
        client.emitConnected(identifier); await Task.yield()
        client.emitServices(identifier, serviceUUIDs: [BleConstants.serviceUUID]); await Task.yield()
        client.emitCharacteristics(identifier, serviceUUID: BleConstants.serviceUUID,
                                   characteristicUUIDs: [BleConstants.notificationCharacteristicUUID, BleConstants.controlCharacteristicUUID])
        await Task.yield()
        client.emitNotificationState(identifier, characteristicUUID: BleConstants.notificationCharacteristicUUID, isNotifying: true)
        await Task.yield()
        XCTAssertEqual(harness.previewReadyCount, 1)
        client.emitNotificationState(identifier, characteristicUUID: BleConstants.notificationCharacteristicUUID,
                                     isNotifying: false, error: NSError(domain: "Synthetic CCC failure after V2 readiness", code: 8))
        await Task.yield()
        XCTAssertEqual(harness.manager.currentState(), .failed)
        XCTAssertEqual(harness.errors.last?.message, "Failed to enable BLE notifications")
        XCTAssertEqual(harness.manager.currentPeripheralIdentifier(), identifier)
        XCTAssertTrue(client.disconnectedIdentifiers.isEmpty, "Notification errors do not authorize stopping an unknown SD recording")
        harness.manager.disconnect()
        XCTAssertEqual(client.disconnectedIdentifiers, [identifier])
    }

    func testV2PreviewWaitsForControlAndCCCWithoutPreparingLegacyCapture() async {
        let client = FakeBleCentralClient(); let harness = BleHarness(client: client); let identifier = UUID()
        client.emitDiscoveredDevice(.init(id: identifier, name: "V2 fixture")); await Task.yield()
        var prepared = false
        await harness.manager.connect(to: identifier, purpose: .v2Preview) { prepared = true }
        XCTAssertFalse(prepared, "Preview must not prepare a recording or video")
        client.emitConnected(identifier); await Task.yield()
        // A stale CCC callback before this discovery must not enable preview.
        client.emitNotificationState(identifier, characteristicUUID: BleConstants.notificationCharacteristicUUID, isNotifying: true)
        await Task.yield()
        XCTAssertEqual(harness.previewReadyCount, 0)
    }

    func testV2PreviewRoutesBytesSeparatelyAndWaitsForRealDisconnectBeforeReconnect() async {
        let client = FakeBleCentralClient(); let harness = BleHarness(client: client); let identifier = UUID()
        client.emitDiscoveredDevice(.init(id: identifier, name: "V2 fixture")); await Task.yield()
        await harness.manager.connect(to: identifier, purpose: .v2Preview)
        client.emitConnected(identifier); await Task.yield()
        client.emitServices(identifier, serviceUUIDs: [BleConstants.serviceUUID]); await Task.yield()
        XCTAssertEqual(client.discoveredCharacteristics.last?.characteristicUUIDs, [BleConstants.notificationCharacteristicUUID, BleConstants.controlCharacteristicUUID])
        client.emitCharacteristics(identifier, serviceUUID: BleConstants.serviceUUID,
                                   characteristicUUIDs: [BleConstants.notificationCharacteristicUUID, BleConstants.controlCharacteristicUUID])
        await Task.yield()
        client.emitNotificationState(identifier, characteristicUUID: BleConstants.notificationCharacteristicUUID, isNotifying: true)
        // Notification bytes may arrive before MainActor processes readiness.
        client.emitNotificationData(Data([1, 2, 0]), identifier: identifier, characteristicUUID: BleConstants.notificationCharacteristicUUID)
        await Task.yield()
        XCTAssertEqual(harness.previewReadyCount, 1); XCTAssertEqual(harness.captureReadyCount, 0)
        XCTAssertEqual(harness.previewFragments, [Data([1, 2, 0])]); XCTAssertTrue(harness.packetFragments.isEmpty)
        harness.manager.disconnect()
        XCTAssertEqual(harness.manager.currentPeripheralIdentifier(), identifier)
        let reconnect = await harness.manager.connect(to: identifier, purpose: .record)
        XCTAssertFalse(reconnect)
        client.emitDisconnected(identifier); await Task.yield()
        XCTAssertNil(harness.manager.currentPeripheralIdentifier())
        let accepted = await harness.manager.connect(to: identifier, purpose: .record)
        XCTAssertTrue(accepted)
    }

    func testCoreBluetoothShortUUIDsExpandToBluetoothBaseUUID() {
        XCTAssertEqual(
            CBUUID(string: "FFF0").foundationUUID,
            UUID(uuidString: "0000fff0-0000-1000-8000-00805f9b34fb")
        )
        XCTAssertEqual(
            CBUUID(string: "12345678").foundationUUID,
            UUID(uuidString: "12345678-0000-1000-8000-00805f9b34fb")
        )
    }
}

@MainActor
private final class BleHarness {
    private(set) var manager: BleSessionManager!
    private let packetFragmentRecorder = LockedValues<Data>()
    private let previewFragmentRecorder = LockedValues<Data>()
    var previewFragments: [Data] { previewFragmentRecorder.values }
    var previewReadyCount = 0
    var devices: [BleDevice] = []
    var packetFragments: [Data] { packetFragmentRecorder.values }
    var diagnostics: [String] = []
    var captureReadyCount = 0
    var states: [BleSessionState] = []
    var errors: [(message: String, error: Error?)] = []

    init(client: FakeBleCentralClient) {
        self.manager = BleSessionManager(
            centralClient: client,
            scanTimeoutMillis: nil,
            onDeviceFound: { [weak self] device in self?.devices.append(device) },
            onPacketReceived: { [packetFragmentRecorder] data in packetFragmentRecorder.append(data) },
            onDiagnosticMessage: { [weak self] message in self?.diagnostics.append(message) },
            onCaptureReady: { [weak self] in self?.captureReadyCount += 1 },
            onStateChanged: { [weak self] state in self?.states.append(state) },
            onError: { [weak self] message, error in self?.errors.append((message, error)) },
            onPreviewReady: { [weak self] in self?.previewReadyCount += 1 },
            onPreviewBytes: { [previewFragmentRecorder] data in previewFragmentRecorder.append(data) }
        )
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
}

private final class FakeBleCentralClient: BleCentralClient {
    weak var delegate: BleCentralClientDelegate?
    var powerState: BleCentralPowerState
    var authorization: BleCentralAuthorization

    var scanRequests: [[UUID]?] = []
    var stopScanCount = 0
    var connectedIdentifiers: [UUID] = []
    var disconnectedIdentifiers: [UUID] = []
    var discoveredServices: [ServiceDiscoveryRequest] = []
    var discoveredCharacteristics: [CharacteristicDiscoveryRequest] = []
    var notifyRequests: [NotifyRequest] = []

    init(
        powerState: BleCentralPowerState = .poweredOn,
        authorization: BleCentralAuthorization = .allowed
    ) {
        self.powerState = powerState
        self.authorization = authorization
    }

    func startScanning(serviceUUIDs: [UUID]?) {
        scanRequests.append(serviceUUIDs)
    }

    func stopScanning() {
        stopScanCount += 1
    }

    func connect(to identifier: UUID) {
        connectedIdentifiers.append(identifier)
    }

    func disconnect(from identifier: UUID) {
        disconnectedIdentifiers.append(identifier)
    }

    func discoverServices(_ serviceUUIDs: [UUID], for identifier: UUID) {
        discoveredServices.append(ServiceDiscoveryRequest(identifier: identifier, serviceUUIDs: serviceUUIDs))
    }

    func discoverCharacteristics(_ characteristicUUIDs: [UUID], serviceUUID: UUID, for identifier: UUID) {
        discoveredCharacteristics.append(
            CharacteristicDiscoveryRequest(
                identifier: identifier,
                serviceUUID: serviceUUID,
                characteristicUUIDs: characteristicUUIDs
            )
        )
    }

    func setNotifyValue(_ enabled: Bool, characteristicUUID: UUID, for identifier: UUID) {
        notifyRequests.append(NotifyRequest(identifier: identifier, characteristicUUID: characteristicUUID, enabled: enabled))
    }

    func emitDiscoveredDevice(_ device: BleDevice) {
        delegate?.centralClient(self, didDiscover: device)
    }

    func emitStateUpdated() {
        delegate?.centralClientDidUpdateState(self)
    }

    func emitConnected(_ identifier: UUID) {
        delegate?.centralClient(self, didConnect: identifier)
    }

    func emitFailedToConnect(_ identifier: UUID, error: Error? = nil) {
        delegate?.centralClient(self, didFailToConnect: identifier, error: error)
    }

    func emitServices(_ identifier: UUID, serviceUUIDs: [UUID], error: Error? = nil) {
        delegate?.centralClient(self, didDiscoverServicesFor: identifier, serviceUUIDs: serviceUUIDs, error: error)
    }

    func emitDisconnected(_ identifier: UUID, error: Error? = nil) {
        delegate?.centralClient(self, didDisconnect: identifier, error: error)
    }

    func emitCharacteristics(_ identifier: UUID, serviceUUID: UUID, characteristicUUIDs: [UUID], error: Error? = nil) {
        delegate?.centralClient(
            self,
            didDiscoverCharacteristicsFor: identifier,
            serviceUUID: serviceUUID,
            characteristicUUIDs: characteristicUUIDs,
            error: error
        )
    }

    func emitNotificationState(
        _ identifier: UUID,
        characteristicUUID: UUID,
        isNotifying: Bool,
        error: Error? = nil
    ) {
        delegate?.centralClient(
            self,
            didUpdateNotificationStateFor: identifier,
            characteristicUUID: characteristicUUID,
            isNotifying: isNotifying,
            error: error
        )
    }

    func emitNotificationData(_ data: Data, identifier: UUID, characteristicUUID: UUID) {
        delegate?.centralClient(
            self,
            didReceiveNotificationData: data,
            identifier: identifier,
            characteristicUUID: characteristicUUID
        )
    }

    func emitNotificationError(_ error: Error, identifier: UUID, characteristicUUID: UUID) {
        delegate?.centralClient(
            self,
            didReceiveNotificationError: error,
            identifier: identifier,
            characteristicUUID: characteristicUUID
        )
    }
}

private struct ServiceDiscoveryRequest: Equatable {
    let identifier: UUID
    let serviceUUIDs: [UUID]
}

private struct CharacteristicDiscoveryRequest: Equatable {
    let identifier: UUID
    let serviceUUID: UUID
    let characteristicUUIDs: [UUID]
}

private struct NotifyRequest: Equatable {
    let identifier: UUID
    let characteristicUUID: UUID
    let enabled: Bool
}
