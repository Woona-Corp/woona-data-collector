import Foundation

actor PacketCaptureProcessor {
    private let packetFileStore: PacketFileStore
    private let rawFragmentFileStore: RawFragmentFileStore
    private let packetTimelineFileStore: PacketTimelineFileStore?
    private let diagnosticLogFileStore: DiagnosticLogFileStore
    private let packetAssembler: PacketAssembler
    private let packetStats: PacketStatsTracker
    private let packetValidator: PacketValidator
    private let wallClockMillisProvider: () -> Int64
    private let fragmentTimestampProvider: () -> Int64
    private let summaryIntervalMillis: Int64
    private let maxPendingFragments: Int
    private let onUpdate: @Sendable (PacketProcessingUpdate) async -> Void
    private let onError: @Sendable (String, Error?) async -> Void

    private var storageFailure: (message: String, error: Error?)?
    private var didReportStorageFailure = false
    private var isAcceptingFragments = true
    private var sessionId: UInt64 = 0
    private var pendingFragments: [QueuedFragment] = []
    private var pendingFragmentHeadIndex = 0
    private var isDrainingFragments = false
    private var packetsRejected: UInt64 = 0
    private var timerRegressionRejects: UInt64 = 0
    private var receivedFragmentCount: UInt64 = 0
    private var receivedRawBytes: UInt64 = 0
    private var lastAcceptedTimerMillis: UInt64?
    private var firstAcceptedPacketMonotonicNs: UInt64?
    private var lastAcceptedPacketMonotonicNs: UInt64?
    private var firstAcceptedDeviceTimerMillis: UInt64?
    private var rejectionCounts: [String: UInt64] = [:]
    private var rejectionReasonOrder: [String] = []
    private var nextDiagnosticEventId: UInt64 = 0
    private var lastSummaryWallClockMillis: Int64
    private var maxObservedQueueDepth = 0
    private var queueOverflowCount: UInt64 = 0

    init(
        packetFileStore: PacketFileStore,
        rawFragmentFileStore: RawFragmentFileStore,
        packetTimelineFileStore: PacketTimelineFileStore? = nil,
        diagnosticLogFileStore: DiagnosticLogFileStore,
        packetAssembler: PacketAssembler = PacketAssembler(),
        packetStats: PacketStatsTracker = PacketStatsTracker(),
        packetValidator: PacketValidator = PacketValidator(),
        wallClockMillisProvider: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        fragmentTimestampProvider: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        summaryIntervalMillis: Int64 = 5_000,
        maxPendingFragments: Int = 512,
        onUpdate: @escaping @Sendable (PacketProcessingUpdate) async -> Void,
        onError: @escaping @Sendable (String, Error?) async -> Void = { _, _ in }
    ) {
        self.packetFileStore = packetFileStore
        self.rawFragmentFileStore = rawFragmentFileStore
        self.packetTimelineFileStore = packetTimelineFileStore
        self.diagnosticLogFileStore = diagnosticLogFileStore
        self.packetAssembler = packetAssembler
        self.packetStats = packetStats
        self.packetValidator = packetValidator
        self.wallClockMillisProvider = wallClockMillisProvider
        self.fragmentTimestampProvider = fragmentTimestampProvider
        self.summaryIntervalMillis = summaryIntervalMillis
        self.maxPendingFragments = maxPendingFragments
        self.onUpdate = onUpdate
        self.onError = onError
        self.lastSummaryWallClockMillis = wallClockMillisProvider()
    }

    @discardableResult
    func submit(_ fragment: [UInt8], receivedAtMonotonicNs: UInt64? = nil) async -> PacketSubmitResult {
        guard !fragment.isEmpty else { return .accepted }
        guard isAcceptingFragments else { return .rejected }
        let receivedAtWallClockMillis = fragmentTimestampProvider()

        do {
            try rawFragmentFileStore.appendFragment(
                sequence: Int64(receivedFragmentCount),
                receivedAtMillis: receivedAtWallClockMillis,
                receivedAtMonotonicNs: Int64(bitPattern: receivedAtMonotonicNs ?? 0),
                fragmentBytes: fragment
            )
            receivedFragmentCount += 1
            receivedRawBytes += UInt64(fragment.count)
        } catch {
            emitError("Failed to persist raw fragment", error)
            await reportStorageFailure()
            return .rejected
        }

        let currentQueueDepth = pendingQueueDepth()
        guard currentQueueDepth < maxPendingFragments else {
            queueOverflowCount += 1
            let event = createDiagnosticEvent(
                type: .info,
                message: "Capture queue overflow depth=\(currentQueueDepth) max=\(maxPendingFragments) overflows=\(queueOverflowCount) fragmentBytes=\(fragment.count)"
            )
            await reportStorageFailure()
            await onUpdate(createStatsUpdate(diagnosticEvents: [event]))
            return .overflow
        }

        pendingFragments.append(
            QueuedFragment(
                sessionId: sessionId,
                bytes: fragment,
                receivedAtWallClockMillis: receivedAtWallClockMillis,
                receivedAtMonotonicNs: receivedAtMonotonicNs
            )
        )
        maxObservedQueueDepth = max(maxObservedQueueDepth, pendingQueueDepth())
        scheduleDrainIfNeeded()
        return .accepted
    }

    func recordDiagnosticEvent(type: PacketDiagnosticType, message: String, publish: Bool = true) async {
        guard storageFailure == nil else { return }
        let event = createDiagnosticEvent(type: type, message: message)
        await reportStorageFailure()
        if publish {
            await onUpdate(createStatsUpdate(diagnosticEvents: [event]))
        }
    }

    func stopCapture() {
        isAcceptingFragments = false
        sessionId += 1
        pendingFragments.removeAll(keepingCapacity: true)
        pendingFragmentHeadIndex = 0
        packetAssembler.reset()
    }

    func finishCaptureSession() async {
        isAcceptingFragments = false
        await waitForDrainCompletion()
        await drainQueuedFragments()
        sessionId += 1
        pendingFragments.removeAll(keepingCapacity: true)
        pendingFragmentHeadIndex = 0
        packetAssembler.reset()

        // Attempt every writer even when another writer cannot flush.
        let closeWriters: [() throws -> Void] = [
            { try self.diagnosticLogFileStore.closeCurrentSession() },
            { try self.rawFragmentFileStore.closeCurrentSession() },
            { try self.packetFileStore.closeCurrentSession() },
            { try self.packetTimelineFileStore?.closeCurrentSession() }
        ]
        for closeWriter in closeWriters {
            do { try closeWriter() }
            catch { emitError("Failed to finish capture session", error) }
        }
        await reportStorageFailure()
    }

    func resetSession() async {
        isAcceptingFragments = false
        sessionId += 1
        pendingFragments.removeAll(keepingCapacity: true)
        pendingFragmentHeadIndex = 0
        packetAssembler.reset()

        await waitForDrainCompletion()
        storageFailure = nil
        didReportStorageFailure = false

        do {
            packetStats.reset()
            packetsRejected = 0
            timerRegressionRejects = 0
            receivedFragmentCount = 0
            receivedRawBytes = 0
            lastAcceptedTimerMillis = nil
            firstAcceptedPacketMonotonicNs = nil
            lastAcceptedPacketMonotonicNs = nil
            firstAcceptedDeviceTimerMillis = nil
            rejectionCounts.removeAll(keepingCapacity: true)
            rejectionReasonOrder.removeAll(keepingCapacity: true)
            nextDiagnosticEventId = 0
            lastSummaryWallClockMillis = wallClockMillisProvider()
            maxObservedQueueDepth = 0
            queueOverflowCount = 0
            try packetFileStore.resetSession()
            try rawFragmentFileStore.resetSession()
            try diagnosticLogFileStore.resetSession()
            try packetTimelineFileStore?.resetSession()
            isAcceptingFragments = true
        } catch {
            emitError("Failed to reset capture session", error)
            await reportStorageFailure()
        }
    }

    func flush() async {
        await waitForDrainCompletion()
        await drainQueuedFragments()

        do {
            try diagnosticLogFileStore.flush()
            try rawFragmentFileStore.flush()
            try packetFileStore.flush()
            try packetTimelineFileStore?.flush()
        } catch {
            emitError("Failed to flush buffered output", error)
            await reportStorageFailure()
        }
    }

    func close() async {
        await finishCaptureSession()
        let closeWriters: [() throws -> Void] = [
            { try self.diagnosticLogFileStore.close() },
            { try self.rawFragmentFileStore.close() },
            { try self.packetFileStore.close() },
            { try self.packetTimelineFileStore?.close() }
        ]
        for closeWriter in closeWriters {
            do { try closeWriter() }
            catch { emitError("Failed to close buffered output", error) }
        }
        await reportStorageFailure()
    }

    func currentPacketFile() -> URL? {
        packetFileStore.currentFile()
    }

    func acceptedPacketTiming() -> (first: UInt64, last: UInt64, deviceTimer: UInt64)? {
        guard let first = firstAcceptedPacketMonotonicNs,
              let last = lastAcceptedPacketMonotonicNs,
              let deviceTimer = firstAcceptedDeviceTimerMillis else { return nil }
        return (first, last, deviceTimer)
    }

    func currentRawFile() -> URL? {
        rawFragmentFileStore.currentFile()
    }

    func currentLogFile() -> URL? {
        diagnosticLogFileStore.currentFile()
    }

    func currentTimelineFile() -> URL? {
        packetTimelineFileStore?.currentFile()
    }

    func hasOpenOutputFiles() -> Bool {
        packetFileStore.hasOpenFileHandle()
            || rawFragmentFileStore.hasOpenFileHandle()
            || diagnosticLogFileStore.hasOpenFileHandle()
            || packetTimelineFileStore?.hasOpenFileHandle() == true
    }

#if DEBUG
    func sessionIdForTesting() -> UInt64 {
        sessionId
    }

    func pendingQueueDepthForTesting() -> Int {
        pendingQueueDepth()
    }
#endif

    private func scheduleDrainIfNeeded() {
        guard !isDrainingFragments else { return }
        isDrainingFragments = true
        Task(priority: .userInitiated) {
            await drainQueuedFragments(ownsDrainFlag: true)
        }
    }

    private func drainQueuedFragments(ownsDrainFlag: Bool = false) async {
        if !ownsDrainFlag {
            guard !isDrainingFragments else { return }
            isDrainingFragments = true
        }
        defer { isDrainingFragments = false }

        while pendingFragmentHeadIndex < pendingFragments.count {
            let queuedFragment = pendingFragments[pendingFragmentHeadIndex]
            pendingFragmentHeadIndex += 1
            compactPendingFragmentsIfNeeded(force: false)
            guard queuedFragment.sessionId == sessionId else { continue }

            let updates = processFragment(
                queuedFragment.bytes,
                receivedAtWallClockMillis: queuedFragment.receivedAtWallClockMillis,
                receivedAtMonotonicNs: queuedFragment.receivedAtMonotonicNs
            )
            await reportStorageFailure()
            for update in updates {
                await onUpdate(update)
            }
        }
        compactPendingFragmentsIfNeeded(force: true)
    }

    private func waitForDrainCompletion() async {
        while isDrainingFragments {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func pendingQueueDepth() -> Int {
        max(pendingFragments.count - pendingFragmentHeadIndex, 0)
    }

    private func compactPendingFragmentsIfNeeded(force: Bool) {
        guard pendingFragmentHeadIndex > 0 else { return }
        guard force || pendingFragmentHeadIndex >= 128 else { return }
        pendingFragments.removeSubrange(0..<pendingFragmentHeadIndex)
        pendingFragmentHeadIndex = 0
    }

    private func processFragment(
        _ fragment: [UInt8],
        receivedAtWallClockMillis: Int64,
        receivedAtMonotonicNs: UInt64?
    ) -> [PacketProcessingUpdate] {
        var updates: [PacketProcessingUpdate] = []

        guard storageFailure == nil else { return [] }
        for assemblyResult in packetAssembler.append(fragment) {
            guard storageFailure == nil else { break }
            switch assemblyResult {
            case .rejected(let reason):
                let message = reason.diagnosticMessage
                registerRejection(reason.rawValue)
                updates.append(
                    createStatsUpdate(
                        lastPacketIssue: message,
                        diagnosticEvents: [
                            createDiagnosticEvent(type: .rejected, message: rejectedPacketMessage(reason: message))
                        ]
                    )
                )

            case .completed(let completedPacket):
                updates.append(
                    contentsOf: processCompletedPacket(
                        completedPacket,
                        receivedAtWallClockMillis: receivedAtWallClockMillis,
                        receivedAtMonotonicNs: receivedAtMonotonicNs
                    )
                )
            }
        }

        if let summaryUpdate = maybeCreateSummaryUpdate() {
            updates.append(summaryUpdate)
        }

        return updates
    }

    private func processCompletedPacket(
        _ completedPacket: CompletedPacket,
        receivedAtWallClockMillis: Int64,
        receivedAtMonotonicNs: UInt64?
    ) -> [PacketProcessingUpdate] {
        switch packetValidator.validate(completedPacket.bytes, sensorBlocks: completedPacket.sensorBlocks) {
        case .rejected(let reason):
            let message = reason.rawValue
            registerRejection(message)
            return [
                createStatsUpdate(
                    lastPacketIssue: message,
                    diagnosticEvents: [
                        createDiagnosticEvent(
                            type: .rejected,
                            message: rejectedPacketMessage(reason: message, packetLength: completedPacket.bytes.count)
                        )
                    ]
                )
            ]

        case .accepted(let packet):
            if let lastAcceptedTimerMillis, packet.timerMillis < lastAcceptedTimerMillis {
                let message = "Packet timer regressed"
                registerRejection(message)
                timerRegressionRejects += 1
                return [
                    createStatsUpdate(
                        lastPacketIssue: message,
                        diagnosticEvents: [
                            createDiagnosticEvent(
                                type: .rejected,
                                message: rejectedPacketMessage(
                                    reason: message,
                                    packetLength: packet.bytes.count,
                                    counter: packet.counter,
                                    timerMillis: packet.timerMillis
                                )
                            )
                        ]
                    )
                ]
            }

            do {
                try packetFileStore.append(packet.bytes)
                if let receivedAtMonotonicNs {
                    try packetTimelineFileStore?.append(
                        sequence: Int64(packetStats.snapshot().packetsReceived),
                        counter: Int64(bitPattern: packet.counter),
                        deviceTimerMillis: Int64(bitPattern: packet.timerMillis),
                        hostWallClockMillis: receivedAtWallClockMillis,
                        hostMonotonicNs: Int64(bitPattern: receivedAtMonotonicNs),
                        packetBytes: Int32(packet.bytes.count)
                    )
                    if firstAcceptedPacketMonotonicNs == nil {
                        firstAcceptedPacketMonotonicNs = receivedAtMonotonicNs
                        firstAcceptedDeviceTimerMillis = packet.timerMillis
                    }
                    lastAcceptedPacketMonotonicNs = receivedAtMonotonicNs
                }
            } catch {
                let message = "Failed to write accepted packet"
                registerRejection(message)
                emitError("Failed to append validated packet", error)
                return [
                    createStatsUpdate(
                        lastPacketIssue: message,
                        diagnosticEvents: [
                            createDiagnosticEvent(
                                type: .rejected,
                                message: rejectedPacketMessage(
                                    reason: message,
                                    packetLength: packet.bytes.count,
                                    counter: packet.counter,
                                    timerMillis: packet.timerMillis
                                )
                            )
                        ]
                    )
                ]
            }

            let previousTimer = lastAcceptedTimerMillis
            lastAcceptedTimerMillis = packet.timerMillis
            let recordResult = packetStats.record(counter: packet.counter)
            var events: [PacketDiagnosticEvent] = []

            if recordResult.gapCount > 0 {
                events.append(
                    createDiagnosticEvent(
                        type: .gap,
                        message: gapMessage(
                            expectedCounter: recordResult.expectedCounter,
                            actualCounter: recordResult.actualCounter,
                            gapCount: recordResult.gapCount
                        )
                    )
                )
            }

            events.append(
                createDiagnosticEvent(
                    type: .accepted,
                    message: "Accepted packet counter=\(packet.counter) timer=\(packet.timerMillis) length=\(packet.bytes.count) measurements=\(packet.measurementCount)"
                )
            )

            return [
                PacketProcessingUpdate(
                    packetsReceived: recordResult.snapshot.packetsReceived,
                    packetsLost: recordResult.snapshot.packetsLost,
                    packetsRejected: packetsRejected,
                    timerRegressionRejects: timerRegressionRejects,
                    fragmentsReceived: receivedFragmentCount,
                    rawBytesReceived: receivedRawBytes,
                    chartSamplesByStream: buildChartSamplesByStream(
                        packet: packet,
                        previousTimerMillis: recordResult.gapCount > 0 ? nil : previousTimer,
                        startsNewSegment: recordResult.gapCount > 0
                    ),
                    rejectionBreakdown: buildRejectionBreakdown(),
                    diagnosticEvents: events
                )
            ]
        }
    }

    private func buildChartSamplesByStream(
        packet: ValidatedPacket,
        previousTimerMillis: UInt64?,
        startsNewSegment: Bool
    ) -> [ChartStreamKey: [ChartPoint]] {
        var samplesByStream: [ChartStreamKey: [Float]] = [:]
        var streamOrder: [ChartStreamKey] = []

        for block in packet.sensorBlocks {
            for (channelIndex, channelSamples) in block.channelSamples.enumerated() {
                let sampledChannel = downsample(channelSamples)
                guard !sampledChannel.isEmpty else { continue }

                let key = ChartStreamKey(sensorType: block.sensorType, channel: channelIndex + 1)
                if samplesByStream[key] == nil {
                    streamOrder.append(key)
                }
                samplesByStream[key, default: []].append(contentsOf: sampledChannel)
            }
        }

        var result: [ChartStreamKey: [ChartPoint]] = [:]
        for key in streamOrder {
            result[key] = buildTimedChartPoints(
                samples: samplesByStream[key] ?? [],
                currentTimerMillis: packet.timerMillis,
                previousTimerMillis: previousTimerMillis,
                startsNewSegment: startsNewSegment
            )
        }
        return result
    }

    private func buildTimedChartPoints(
        samples: [Float],
        currentTimerMillis: UInt64,
        previousTimerMillis: UInt64?,
        startsNewSegment: Bool
    ) -> [ChartPoint] {
        guard !samples.isEmpty else { return [] }

        let intervalMillis: UInt64?
        if let previousTimerMillis, currentTimerMillis > previousTimerMillis {
            intervalMillis = currentTimerMillis - previousTimerMillis
        } else {
            intervalMillis = nil
        }

        return samples.enumerated().map { index, value in
            let timeMillis: UInt64
            if samples.count == 1 {
                timeMillis = currentTimerMillis
            } else if let intervalMillis, let previousTimerMillis {
                timeMillis = previousTimerMillis + (intervalMillis * UInt64(index + 1) / UInt64(samples.count))
            } else {
                timeMillis = currentTimerMillis
            }

            return ChartPoint(
                timeMillis: timeMillis,
                value: value,
                startsNewSegment: startsNewSegment && index == 0
            )
        }
    }

    private func downsample(_ samples: [Float]) -> [Float] {
        guard samples.count > Self.chartDownsampleThreshold else { return samples }
        return samples.enumerated().compactMap { index, sample in
            index.isMultiple(of: Self.chartDownsampleStep) ? sample : nil
        }
    }

    private func registerRejection(_ reason: String) {
        packetsRejected += 1
        if rejectionCounts[reason] == nil {
            rejectionReasonOrder.append(reason)
        }
        rejectionCounts[reason, default: 0] += 1
    }

    private func buildRejectionBreakdown() -> String? {
        guard !rejectionReasonOrder.isEmpty else { return nil }
        return rejectionReasonOrder.compactMap { reason in
            guard let count = rejectionCounts[reason] else { return nil }
            return "\(reason): \(count)"
        }.joined(separator: " | ")
    }

    private func createStatsUpdate(
        chartSamplesByStream: [ChartStreamKey: [ChartPoint]] = [:],
        lastPacketIssue: String? = nil,
        diagnosticEvents: [PacketDiagnosticEvent] = []
    ) -> PacketProcessingUpdate {
        let snapshot = packetStats.snapshot()
        return PacketProcessingUpdate(
            packetsReceived: snapshot.packetsReceived,
            packetsLost: snapshot.packetsLost,
            packetsRejected: packetsRejected,
            timerRegressionRejects: timerRegressionRejects,
            fragmentsReceived: receivedFragmentCount,
            rawBytesReceived: receivedRawBytes,
            chartSamplesByStream: chartSamplesByStream,
            lastPacketIssue: lastPacketIssue,
            rejectionBreakdown: buildRejectionBreakdown(),
            diagnosticEvents: diagnosticEvents
        )
    }

    private func maybeCreateSummaryUpdate() -> PacketProcessingUpdate? {
        let now = wallClockMillisProvider()
        guard now - lastSummaryWallClockMillis >= summaryIntervalMillis else { return nil }
        lastSummaryWallClockMillis = now

        let snapshot = packetStats.snapshot()
        let event = createDiagnosticEvent(
            type: .info,
            message: "Capture summary: received=\(snapshot.packetsReceived) lost=\(snapshot.packetsLost) rejected=\(packetsRejected) timerRegressionRejects=\(timerRegressionRejects) fragments=\(receivedFragmentCount) rawBytes=\(receivedRawBytes) queueDepth=\(pendingQueueDepth()) maxQueueDepth=\(maxObservedQueueDepth) queueOverflows=\(queueOverflowCount)"
        )
        return createStatsUpdate(diagnosticEvents: [event])
    }

    private func createDiagnosticEvent(type: PacketDiagnosticType, message: String) -> PacketDiagnosticEvent {
        let event = PacketDiagnosticEvent(id: nextDiagnosticEventId, type: type, message: message)
        nextDiagnosticEventId += 1

        guard storageFailure == nil else { return event }
        do {
            try diagnosticLogFileStore.appendEvent(
                eventId: Int64(event.id),
                type: event.type.rawValue,
                message: event.message
            )
        } catch {
            emitError("Failed to persist diagnostic log event", error)
        }

        return event
    }

    private func gapMessage(expectedCounter: UInt64?, actualCounter: UInt64?, gapCount: UInt64) -> String {
        let expected = expectedCounter.map(String.init) ?? "?"
        let actual = actualCounter.map(String.init) ?? "?"
        return "Gap detected expected=\(expected) actual=\(actual) lost=\(gapCount)"
    }

    private func rejectedPacketMessage(
        reason: String,
        packetLength: Int? = nil,
        counter: UInt64? = nil,
        timerMillis: UInt64? = nil
    ) -> String {
        var details = ["reason=\(reason)"]
        if let packetLength {
            details.append("length=\(packetLength)")
        }
        if let counter {
            details.append("counter=\(counter)")
        }
        if let timerMillis {
            details.append("timer=\(timerMillis)")
        }
        return "Rejected packet \(details.joined(separator: ", "))"
    }

    private static let chartDownsampleThreshold = 500
    private static let chartDownsampleStep = 4

    private func emitError(_ message: String, _ error: Error?) {
        guard storageFailure == nil else { return }
        storageFailure = (message, error)
        isAcceptingFragments = false
    }

    private func reportStorageFailure() async {
        guard let storageFailure, !didReportStorageFailure else { return }
        didReportStorageFailure = true
        await onError(storageFailure.message, storageFailure.error)
    }

    private struct QueuedFragment {
        let sessionId: UInt64
        let bytes: [UInt8]
        let receivedAtWallClockMillis: Int64
        let receivedAtMonotonicNs: UInt64?
    }
}
