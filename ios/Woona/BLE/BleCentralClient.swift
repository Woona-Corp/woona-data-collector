import Foundation

protocol BleCentralClient: AnyObject {
    var delegate: BleCentralClientDelegate? { get set }
    var powerState: BleCentralPowerState { get }
    var authorization: BleCentralAuthorization { get }

    func startScanning(serviceUUIDs: [UUID]?)
    func stopScanning()
    func connect(to identifier: UUID)
    func disconnect(from identifier: UUID)
    func discoverServices(_ serviceUUIDs: [UUID], for identifier: UUID)
    func discoverCharacteristics(_ characteristicUUIDs: [UUID], serviceUUID: UUID, for identifier: UUID)
    func setNotifyValue(_ enabled: Bool, characteristicUUID: UUID, for identifier: UUID)
    func writeControlFrame(_ data: Data, characteristicUUID: UUID, for identifier: UUID,
                           completion: @escaping BleControlWriteQueue.Completion)
    func cancelControlWrites(for identifier: UUID)
}

extension BleCentralClient {
    func writeControlFrame(_ data: Data, characteristicUUID: UUID, for identifier: UUID,
                           completion: @escaping BleControlWriteQueue.Completion) {
        completion(.failure(BleControlWriteError.writeUnsupported))
    }
    func cancelControlWrites(for identifier: UUID) {}
}

enum BleCentralClientError: Error, Equatable, LocalizedError {
    case peripheralReferenceMissing(UUID)
    case serviceReferenceMissing(identifier: UUID, serviceUUID: UUID)
    case characteristicReferenceMissing(identifier: UUID, characteristicUUID: UUID)

    var errorDescription: String? {
        switch self {
        case .peripheralReferenceMissing(let identifier):
            "Missing CoreBluetooth peripheral reference for \(identifier.uuidString)"
        case .serviceReferenceMissing(let identifier, let serviceUUID):
            "Missing CoreBluetooth service \(serviceUUID.uuidString) for \(identifier.uuidString)"
        case .characteristicReferenceMissing(let identifier, let characteristicUUID):
            "Missing CoreBluetooth characteristic \(characteristicUUID.uuidString) for \(identifier.uuidString)"
        }
    }
}

protocol BleCentralClientDelegate: AnyObject {
    func centralClientDidUpdateState(_ client: BleCentralClient)
    func centralClient(_ client: BleCentralClient, didDiscover device: BleDevice)
    func centralClient(_ client: BleCentralClient, didConnect identifier: UUID)
    func centralClient(_ client: BleCentralClient, didFailToConnect identifier: UUID, error: Error?)
    func centralClient(_ client: BleCentralClient, didDisconnect identifier: UUID, error: Error?)
    func centralClient(_ client: BleCentralClient, didDiscoverServicesFor identifier: UUID, serviceUUIDs: [UUID], error: Error?)
    func centralClient(
        _ client: BleCentralClient,
        didDiscoverCharacteristicsFor identifier: UUID,
        serviceUUID: UUID,
        characteristicUUIDs: [UUID],
        error: Error?
    )
    func centralClient(
        _ client: BleCentralClient,
        didUpdateNotificationStateFor identifier: UUID,
        characteristicUUID: UUID,
        isNotifying: Bool,
        error: Error?
    )
    func centralClient(
        _ client: BleCentralClient,
        didReceiveNotificationData data: Data,
        identifier: UUID,
        characteristicUUID: UUID
    )
    func centralClient(
        _ client: BleCentralClient,
        didReceiveNotificationError error: Error,
        identifier: UUID,
        characteristicUUID: UUID
    )
}
