import CoreBluetooth
import Foundation

final class CoreBluetoothBleCentralClient: NSObject, BleCentralClient {
    weak var delegate: BleCentralClientDelegate?

    private let centralQueue = DispatchQueue(
        label: "com.woona.ble.central",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private lazy var centralManager = CBCentralManager(delegate: self, queue: centralQueue)
    private var peripheralsByIdentifier: [UUID: CBPeripheral] = [:]
    private var serviceByPeripheralAndUUID: [PeripheralServiceKey: CBService] = [:]
    private var characteristicByPeripheralAndUUID: [PeripheralCharacteristicKey: CBCharacteristic] = [:]
    private var controlConnections: [UUID: ControlConnection] = [:]

    var powerState: BleCentralPowerState {
        centralManager.state.blePowerState
    }

    var authorization: BleCentralAuthorization {
        CBCentralManager.authorization.bleAuthorization
    }

    func startScanning(serviceUUIDs: [UUID]?) {
        centralQueue.async { [weak self] in
            guard let self else { return }
            let services = serviceUUIDs?.map { CBUUID(nsuuid: $0) }
            centralManager.scanForPeripherals(withServices: services)
        }
    }

    func stopScanning() {
        centralQueue.async { [weak self] in
            self?.centralManager.stopScan()
        }
    }

    func connect(to identifier: UUID) {
        centralQueue.async { [weak self] in
            guard let self else { return }
            guard let peripheral = peripheralsByIdentifier[identifier] else {
                delegate?.centralClient(self, didFailToConnect: identifier, error: BleCentralClientError.peripheralReferenceMissing(identifier))
                return
            }
            peripheral.delegate = self
            centralManager.connect(peripheral)
        }
    }

    func disconnect(from identifier: UUID) {
        centralQueue.async { [weak self] in
            guard let self else { return }
            guard let peripheral = peripheralsByIdentifier[identifier] else {
                delegate?.centralClient(self, didDisconnect: identifier, error: BleCentralClientError.peripheralReferenceMissing(identifier))
                return
            }
            controlConnections.removeValue(forKey: identifier)?.queue.reset()
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    func discoverServices(_ serviceUUIDs: [UUID], for identifier: UUID) {
        centralQueue.async { [weak self] in
            guard let self else { return }
            guard let peripheral = peripheralsByIdentifier[identifier] else {
                delegate?.centralClient(
                    self,
                    didDiscoverServicesFor: identifier,
                    serviceUUIDs: [],
                    error: BleCentralClientError.peripheralReferenceMissing(identifier)
                )
                return
            }
            let services = serviceUUIDs.map { CBUUID(nsuuid: $0) }
            peripheral.discoverServices(services)
        }
    }

    func discoverCharacteristics(_ characteristicUUIDs: [UUID], serviceUUID: UUID, for identifier: UUID) {
        centralQueue.async { [weak self] in
            guard let self else { return }
            guard let peripheral = peripheralsByIdentifier[identifier] else {
                delegate?.centralClient(
                    self,
                    didDiscoverCharacteristicsFor: identifier,
                    serviceUUID: serviceUUID,
                    characteristicUUIDs: [],
                    error: BleCentralClientError.peripheralReferenceMissing(identifier)
                )
                return
            }
            guard let service = serviceByPeripheralAndUUID[PeripheralServiceKey(peripheralID: identifier, serviceUUID: serviceUUID)] else {
                delegate?.centralClient(
                    self,
                    didDiscoverCharacteristicsFor: identifier,
                    serviceUUID: serviceUUID,
                    characteristicUUIDs: [],
                    error: BleCentralClientError.serviceReferenceMissing(identifier: identifier, serviceUUID: serviceUUID)
                )
                return
            }

            let characteristics = characteristicUUIDs.map { CBUUID(nsuuid: $0) }
            peripheral.discoverCharacteristics(characteristics, for: service)
        }
    }

    func setNotifyValue(_ enabled: Bool, characteristicUUID: UUID, for identifier: UUID) {
        centralQueue.async { [weak self] in
            guard let self else { return }
            guard let peripheral = peripheralsByIdentifier[identifier] else {
                delegate?.centralClient(
                    self,
                    didUpdateNotificationStateFor: identifier,
                    characteristicUUID: characteristicUUID,
                    isNotifying: false,
                    error: BleCentralClientError.peripheralReferenceMissing(identifier)
                )
                return
            }
            guard let characteristic = characteristicByPeripheralAndUUID[
                PeripheralCharacteristicKey(peripheralID: identifier, characteristicUUID: characteristicUUID)
            ] else {
                delegate?.centralClient(
                    self,
                    didUpdateNotificationStateFor: identifier,
                    characteristicUUID: characteristicUUID,
                    isNotifying: false,
                    error: BleCentralClientError.characteristicReferenceMissing(identifier: identifier, characteristicUUID: characteristicUUID)
                )
                return
            }

            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    func writeControlFrame(_ data: Data, characteristicUUID: UUID, for identifier: UUID,
                           completion: @escaping BleControlWriteQueue.Completion) {
        centralQueue.async { [weak self] in
            guard let self, let peripheral = self.peripheralsByIdentifier[identifier], peripheral.state == .connected else {
                completion(.failure(BleControlWriteError.disconnected)); return
            }
            guard let characteristic = self.characteristicByPeripheralAndUUID[
                PeripheralCharacteristicKey(peripheralID: identifier, characteristicUUID: characteristicUUID)
            ] else { completion(.failure(BleControlWriteError.characteristicUnavailable)); return }
            guard characteristic.properties.contains(.write) else {
                completion(.failure(BleControlWriteError.writeUnsupported)); return
            }
            let connection: ControlConnection
            if let existing = self.controlConnections[identifier], existing.characteristic === characteristic {
                connection = existing
            } else {
                self.controlConnections.removeValue(forKey: identifier)?.queue.reset()
                connection = ControlConnection(peripheral: peripheral, characteristic: characteristic)
                self.controlConnections[identifier] = connection
            }
            do {
                try connection.queue.enqueue(data, maximumChunkBytes: peripheral.maximumWriteValueLength(for: .withResponse), completion: completion)
                self.drainControlWrite(connection)
            } catch { completion(.failure(error)) }
        }
    }

    func cancelControlWrites(for identifier: UUID) {
        centralQueue.async { [weak self] in self?.controlConnections.removeValue(forKey: identifier)?.queue.reset() }
    }

    private func drainControlWrite(_ connection: ControlConnection) {
        guard connection.peripheral.state == .connected else {
            connection.queue.reset(); return
        }
        if let fragment = connection.queue.nextFragment() {
            connection.peripheral.writeValue(fragment, for: connection.characteristic, type: .withResponse)
        }
    }

    private func isCurrent(_ characteristic: CBCharacteristic, peripheral: CBPeripheral) -> Bool {
        guard let uuid = characteristic.uuid.foundationUUID else { return false }
        return characteristicByPeripheralAndUUID[PeripheralCharacteristicKey(peripheralID: peripheral.identifier, characteristicUUID: uuid)] === characteristic
    }

    private func remember(_ peripheral: CBPeripheral) {
        peripheralsByIdentifier[peripheral.identifier] = peripheral
    }

    private func clearDiscoveryCaches(for identifier: UUID) {
        controlConnections.removeValue(forKey: identifier)?.queue.reset()
        serviceByPeripheralAndUUID = serviceByPeripheralAndUUID.filter { $0.key.peripheralID != identifier }
        characteristicByPeripheralAndUUID = characteristicByPeripheralAndUUID.filter { $0.key.peripheralID != identifier }
    }
}

extension CoreBluetoothBleCentralClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            for connection in controlConnections.values { connection.queue.reset() }
            controlConnections.removeAll()
        }
        delegate?.centralClientDidUpdateState(self)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        remember(peripheral)
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        delegate?.centralClient(
            self,
            didDiscover: BleDevice(id: peripheral.identifier, name: peripheral.name ?? localName ?? "Unknown device")
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        remember(peripheral)
        clearDiscoveryCaches(for: peripheral.identifier)
        peripheral.delegate = self
        delegate?.centralClient(self, didConnect: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        delegate?.centralClient(self, didFailToConnect: peripheral.identifier, error: error)
        clearDiscoveryCaches(for: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        delegate?.centralClient(self, didDisconnect: peripheral.identifier, error: error)
        clearDiscoveryCaches(for: peripheral.identifier)
    }
}

extension CoreBluetoothBleCentralClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let connection = controlConnections[peripheral.identifier],
              connection.characteristic === characteristic else { return }
        connection.queue.acknowledge(error: error)
        drainControlWrite(connection)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let serviceUUIDs = peripheral.services?.compactMap { service -> UUID? in
            guard let uuid = service.uuid.foundationUUID else { return nil }
            serviceByPeripheralAndUUID[PeripheralServiceKey(peripheralID: peripheral.identifier, serviceUUID: uuid)] = service
            return uuid
        } ?? []

        delegate?.centralClient(
            self,
            didDiscoverServicesFor: peripheral.identifier,
            serviceUUIDs: serviceUUIDs,
            error: error
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let serviceUUID = service.uuid.foundationUUID
        let characteristicUUIDs = service.characteristics?.compactMap { characteristic -> UUID? in
            guard let uuid = characteristic.uuid.foundationUUID else { return nil }
            characteristicByPeripheralAndUUID[
                PeripheralCharacteristicKey(peripheralID: peripheral.identifier, characteristicUUID: uuid)
            ] = characteristic
            return uuid
        } ?? []

        delegate?.centralClient(
            self,
            didDiscoverCharacteristicsFor: peripheral.identifier,
            serviceUUID: serviceUUID ?? BleConstants.serviceUUID,
            characteristicUUIDs: characteristicUUIDs,
            error: error
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(characteristic, peripheral: peripheral) else { return }
        delegate?.centralClient(
            self,
            didUpdateNotificationStateFor: peripheral.identifier,
            characteristicUUID: characteristic.uuid.foundationUUID ?? BleConstants.notificationCharacteristicUUID,
            isNotifying: characteristic.isNotifying,
            error: error
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(characteristic, peripheral: peripheral) else { return }
        if let error {
            delegate?.centralClient(
                self,
                didReceiveNotificationError: error,
                identifier: peripheral.identifier,
                characteristicUUID: characteristic.uuid.foundationUUID ?? BleConstants.notificationCharacteristicUUID
            )
            return
        }
        guard let data = characteristic.value else { return }
        let notificationData = Data(data)
        delegate?.centralClient(
            self,
            didReceiveNotificationData: notificationData,
            identifier: peripheral.identifier,
            characteristicUUID: characteristic.uuid.foundationUUID ?? BleConstants.notificationCharacteristicUUID
        )
    }
}

private struct PeripheralServiceKey: Hashable {
    let peripheralID: UUID
    let serviceUUID: UUID
}

private final class ControlConnection {
    let peripheral: CBPeripheral
    let characteristic: CBCharacteristic
    let queue = BleControlWriteQueue()
    init(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        self.peripheral = peripheral; self.characteristic = characteristic
    }
}

private struct PeripheralCharacteristicKey: Hashable {
    let peripheralID: UUID
    let characteristicUUID: UUID
}

private extension CBManagerState {
    var blePowerState: BleCentralPowerState {
        switch self {
        case .unknown:
            .unknown
        case .resetting:
            .resetting
        case .unsupported:
            .unsupported
        case .unauthorized:
            .unauthorized
        case .poweredOff:
            .poweredOff
        case .poweredOn:
            .poweredOn
        @unknown default:
            .unknown
        }
    }
}

private extension CBManagerAuthorization {
    var bleAuthorization: BleCentralAuthorization {
        switch self {
        case .allowedAlways:
            .allowed
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .notDetermined:
            .notDetermined
        @unknown default:
            .notDetermined
        }
    }
}

extension CBUUID {
    var foundationUUID: UUID? {
        let normalized = uuidString.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized.count {
        case 4:
            return UUID(uuidString: "0000\(normalized)-0000-1000-8000-00805f9b34fb")
        case 8:
            return UUID(uuidString: "\(normalized)-0000-1000-8000-00805f9b34fb")
        default:
            return UUID(uuidString: normalized)
        }
    }
}
