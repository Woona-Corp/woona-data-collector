import Foundation

final class PacketFragmentSubmitter: @unchecked Sendable {
    private let packetProcessor: PacketCaptureProcessor
    private let maxPendingFragments: Int
    private let onOverflow: @Sendable () async -> Void
    private let onIngressStop: @Sendable () -> Void
    private let lock = NSLock()

    private var pendingFragments: [QueuedPacketFragment] = []
    private var pendingHeadIndex = 0
    private var isDraining = false
    private var isFinishing = false
    private var generation: UInt64 = 0

    init(
        packetProcessor: PacketCaptureProcessor,
        maxPendingFragments: Int,
        onIngressStop: @escaping @Sendable () -> Void = {},
        onOverflow: @escaping @Sendable () async -> Void
    ) {
        self.packetProcessor = packetProcessor
        self.maxPendingFragments = max(0, maxPendingFragments)
        self.onOverflow = onOverflow
        self.onIngressStop = onIngressStop
    }

    func enqueue(_ data: Data, receivedAtMonotonicNs: UInt64? = nil) {
        enqueue([UInt8](data), receivedAtMonotonicNs: receivedAtMonotonicNs)
    }

    func enqueue(_ bytes: [UInt8], receivedAtMonotonicNs: UInt64? = nil) {
        guard !bytes.isEmpty else { return }

        let action = lock.withLock {
            guard !isFinishing else { return EnqueueAction.none }
            guard pendingQueueDepthLocked() < maxPendingFragments else {
                pendingFragments.append(QueuedPacketFragment(generation: generation,bytes: bytes,receivedAtMonotonicNs: receivedAtMonotonicNs))
                isFinishing = true
                let startDrain = !isDraining
                isDraining = true
                return EnqueueAction.overflow(startDrain)
            }
            pendingFragments.append(
                QueuedPacketFragment(
                    generation: generation,
                    bytes: bytes,
                    receivedAtMonotonicNs: receivedAtMonotonicNs
                )
            )
            guard !isDraining else { return EnqueueAction.none }
            isDraining = true
            return EnqueueAction.startDrain
        }

        switch action {
        case .none:
            break
        case .startDrain:
            Task(priority: .userInitiated) {
                await drain()
            }
        case .overflow(let startDrain):
            onIngressStop()
            if startDrain { Task(priority: .userInitiated) { await drain() } }
            Task(priority: .userInitiated) {
                await onOverflow()
            }
        }
    }

    func reset() async {
        lock.withLock {
            generation += 1
            pendingFragments.removeAll(keepingCapacity: true)
            pendingHeadIndex = 0
            isFinishing = false
        }
        await waitForDrain()
    }

    func finishCaptureProcessing() async {
        lock.withLock {
            isFinishing = true
        }
        await waitForDrain()
        await packetProcessor.finishCaptureSession()
        lock.withLock {
            generation += 1
            pendingFragments.removeAll(keepingCapacity: true)
            pendingHeadIndex = 0
            isFinishing = false
        }
    }

    private func drain() async {
        while true {
            guard let fragment = nextFragment() else {
                let shouldContinue = lock.withLock {
                    if pendingHeadIndex < pendingFragments.count {
                        return true
                    }
                    isDraining = false
                    compactPendingFragmentsLocked(force: true)
                    return false
                }
                if shouldContinue {
                    continue
                }
                return
            }

            let submitResult = await packetProcessor.submit(
                fragment.bytes,
                receivedAtMonotonicNs: fragment.receivedAtMonotonicNs
            )
            if submitResult == .overflow {
                lock.withLock { isFinishing = true }
                onIngressStop()
                await onOverflow()
            }
        }
    }

    private func nextFragment() -> QueuedPacketFragment? {
        lock.withLock {
            while pendingHeadIndex < pendingFragments.count {
                let fragment = pendingFragments[pendingHeadIndex]
                pendingHeadIndex += 1
                compactPendingFragmentsLocked(force: false)
                if fragment.generation == generation {
                    return fragment
                }
            }
            return nil
        }
    }

    private func waitForDrain() async {
        while lock.withLock({ isDraining }) {
            await Task.yield()
        }
    }

    private func pendingQueueDepthLocked() -> Int {
        max(pendingFragments.count - pendingHeadIndex, 0)
    }

    private func compactPendingFragmentsLocked(force: Bool) {
        guard pendingHeadIndex > 0 else { return }
        guard force || pendingHeadIndex >= 128 else { return }
        pendingFragments.removeSubrange(0..<pendingHeadIndex)
        pendingHeadIndex = 0
    }

    private struct QueuedPacketFragment {
        let generation: UInt64
        let bytes: [UInt8]
        let receivedAtMonotonicNs: UInt64?
    }

    private enum EnqueueAction {
        case none
        case startDrain
        case overflow(Bool)
    }
}

final class PacketIngressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    func start() {
        lock.withLock {
            active = true
        }
    }

    func stop() { lock.withLock { active = false } }

    func timestampIfActive() -> UInt64? {
        lock.withLock {
            guard active else { return nil }
            let timestamp = HostClock.nowNanoseconds()
            return timestamp
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
