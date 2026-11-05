import Foundation
import UIKit

@MainActor
final class BackgroundSyncRegistration {
    static let shared = BackgroundSyncRegistration()
    private(set) var attempted = false
    private(set) var registered = false
    private(set) weak var owner: AppViewModel?

    func register(owner: AppViewModel, registrar: () -> Bool) -> Bool {
        self.owner = owner
        guard !attempted else { return registered }
        attempted = true
        registered = registrar()
        return registered
    }
}

@MainActor
enum BackgroundSyncExecution {
    static func start(work: @escaping @MainActor () async -> Bool,
                      completion: @escaping @MainActor (Bool) -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            guard !Task.isCancelled else { completion(false); return }
            let success = await work()
            completion(success && !Task.isCancelled)
        }
    }
}

/// Finite time to close writers and commit local capture metadata. This does
/// not enable background camera recording or promise unlimited background work.
@MainActor
final class CaptureFinalizationBackgroundTime {
    typealias Begin = (@escaping () -> Void) -> UIBackgroundTaskIdentifier
    private let enabled: Bool
    private let beginOperation: Begin
    private let endOperation: (UIBackgroundTaskIdentifier) -> Void
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private var generation: UUID?

    init(enabled: Bool, begin: Begin? = nil, end: ((UIBackgroundTaskIdentifier) -> Void)? = nil) {
        self.enabled = enabled
        beginOperation = begin ?? { expiration in
            UIApplication.shared.beginBackgroundTask(withName: "Woona capture finalization", expirationHandler: expiration)
        }
        endOperation = end ?? { UIApplication.shared.endBackgroundTask($0) }
    }

    func begin(onExpiration: @escaping () -> Void) {
        guard enabled, generation == nil else { return }
        let token = UUID()
        generation = token
        identifier = beginOperation { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.end()
                onExpiration()
            }
        }
        if identifier == .invalid { generation = nil }
    }

    func end() {
        let completed = identifier
        identifier = .invalid; generation = nil
        if completed != .invalid { endOperation(completed) }
    }
}
