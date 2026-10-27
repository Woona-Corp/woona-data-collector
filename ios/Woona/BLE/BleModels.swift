import Foundation

struct BleDevice: Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String

    var stableIdentifier: String {
        id.uuidString
    }
}

enum BleConnectionPurpose: String, Sendable { case record, v2Preview }

enum BleSessionState: Equatable, Sendable {
    case idle
    case scanning
    case connecting
    case connected
    case disconnected
    case failed
}

enum BleSessionEvent: Equatable, Sendable {
    case scanStarted
    case scanStopped
    case connectRequested
    case connected
    case disconnected
    case failure
}

enum BleSessionStateMachine {
    static func transition(
        currentState: BleSessionState,
        event: BleSessionEvent
    ) -> BleSessionState {
        switch event {
        case .scanStarted:
            .scanning
        case .scanStopped:
            currentState == .connected ? .connected : .idle
        case .connectRequested:
            .connecting
        case .connected:
            .connected
        case .disconnected:
            .disconnected
        case .failure:
            .failed
        }
    }
}

enum BleTransportProfile: String, Equatable, Sendable {
    case iosManaged

    var title: String {
        switch self {
        case .iosManaged:
            "iOS managed"
        }
    }
}

enum BleCentralPowerState: Equatable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

enum BleCentralAuthorization: Equatable, Sendable {
    case allowed
    case denied
    case restricted
    case notDetermined
}

struct BleConstants {
    static let serviceUUID = UUID(uuidString: "0000fff0-0000-1000-8000-00805f9b34fb")!
    static let notificationCharacteristicUUID = UUID(uuidString: "0000fff1-0000-1000-8000-00805f9b34fb")!
    static let controlCharacteristicUUID = UUID(uuidString: "0000fff2-0000-1000-8000-00805f9b34fb")!
    static let cccdDescriptorUUID = UUID(uuidString: "00002902-0000-1000-8000-00805f9b34fb")!
}
