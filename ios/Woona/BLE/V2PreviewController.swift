import Foundation
import Combine

struct V2PreviewPoint: Sendable {
    let time: Double
    let value: Double
    var breakBefore: Bool
}

struct V2PreviewChannel: Identifiable, Sendable {
    let streamID: Int
    let channel: Int
    var points: [V2PreviewPoint]
    var id: String { "\(streamID)-\(channel)" }
}

struct V2PreviewSnapshot {
    enum Stage: Equatable { case idle, connecting, checking, ready, starting, running, stopping, stopped, failed }
    var stage = Stage.idle
    var streams: [V2Stream] = []
    var selectedMask: UInt32 = 0
    var reason: String?
    var busySessionMode: Int?
    var decodedBlocks: UInt64 = 0
    var wireGaps: UInt64 = 0
    var rejectedFrames: UInt64 = 0
    var skippedUIBlocks: UInt64 = 0
    var channels: [V2PreviewChannel] = []
}

/// Owns no recording, file writer or server client. All protocol work is confined
/// to one queue; CoreBluetooth ingress uses synchronous backpressure instead of
/// creating an unbounded Task for every notification.
final class V2PreviewWorker: @unchecked Sendable {
    typealias Update = @MainActor (UUID, V2PreviewSnapshot) -> Void
    typealias Write = @MainActor (UUID, Data, @escaping @Sendable (Result<Void, Error>) -> Void) -> Void
    private let queue = DispatchQueue(label: "woona.v2-preview", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let update: Update
    private let write: Write
    private var generation = UUID()
    private var snapshot = V2PreviewSnapshot()
    private var decoder = WoonaV2StreamDecoder()
    private var discovery = WoonaV2Discovery()
    private var live: WoonaV2LiveSession?
    private var responseTimer: DispatchWorkItem?
    private var timerToken = UUID()
    private var flushTimer: DispatchWorkItem?
    private var deliveryPending = false
    private var foreground = true
    private var connected = false
    private var originUs: UInt64?
    private struct PendingBlock { let block: V2LiveData; let descriptor: V2Stream; let gap: Bool }
    private var blocks: [PendingBlock] = []
    private var channels: [String: V2PreviewChannel] = [:]
    private var pendingBreaks: Set<Int> = []

    init(update: @escaping Update, write: @escaping Write) {
        self.update = update; self.write = write
        queue.setSpecific(key: queueKey, value: true)
    }

    func prepare(_ generation: UUID) {
        queue.sync {
            cancelTimers()
            self.generation = generation; snapshot = V2PreviewSnapshot(); snapshot.stage = .connecting
            decoder = WoonaV2StreamDecoder(); discovery = WoonaV2Discovery(); live = nil
            blocks = []; channels = [:]; pendingBreaks = []; originUs = nil
            connected = true; foreground = true
            publish()
        }
    }

    func ready() {
        queue.async { [self] in
            guard connected, snapshot.stage == .connecting else { return }
            snapshot.stage = .checking
            do { handle(try discovery.begin()) } catch { fail(error.localizedDescription) }
            publish()
        }
    }

    func receive(_ data: Data) {
        let consume = { [self] in
            guard connected else { return }
            for frame in decoder.append(data) {
                if discovery.phase != .ready {
                    for event in discovery.receive(frame) { handle(event) }
                } else if let live {
                    for event in live.receive(frame) { handle(event) }
                }
            }
            snapshot.rejectedFrames = decoder.rejectedFrames
            scheduleFlush()
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { consume() }
        else { queue.sync(execute: consume) }
    }

    func select(mask: UInt32) {
        queue.async { [self] in
            guard [.ready, .stopped].contains(snapshot.stage) else { return }
            let knownMask = snapshot.streams.reduce(UInt32(0)) { $0 | (UInt32(1) << ($1.id - 1)) }
            snapshot.selectedMask = mask & knownMask; publish()
        }
    }

    func start() {
        queue.async { [self] in
            guard connected, foreground, [.ready, .stopped].contains(snapshot.stage), let live else { return }
            do {
                let event = try live.start(streamMask: snapshot.selectedMask)
                blocks = []; channels = [:]; pendingBreaks = []; originUs = nil
                snapshot.channels = []; snapshot.decodedBlocks = 0; snapshot.wireGaps = 0; snapshot.skippedUIBlocks = 0
                snapshot.stage = .starting; snapshot.reason = nil; handle(event); publish()
            } catch { fail(error.localizedDescription); publish() }
        }
    }

    func stop() { queue.async { [self] in stopOwnLive(); publish() } }

    func setForeground(_ foreground: Bool) {
        queue.async { [self] in
            self.foreground = foreground
            if !foreground {
                snapshot.skippedUIBlocks += UInt64(blocks.count); blocks = []
                pendingBreaks.formUnion(snapshot.streams.map(\.id))
                stopOwnLive()
            }
            // Never automatically disconnect: before GET_STATUS even an
            // unknown peer may be recording to SD. The firmware warning applies.
            publish()
        }
    }

    func disconnected(reason: String? = nil) {
        queue.async { [self] in
            connected = false; cancelTimers(); blocks = []
            if let reason { snapshot.reason = reason; snapshot.stage = .failed }
            else { snapshot.stage = .stopped }
            publish()
        }
    }

    private func stopOwnLive() {
        guard let live, live.phase == .running else { return }
        do { let event = try live.stop(); snapshot.stage = .stopping; handle(event) }
        catch { fail(error.localizedDescription) }
    }

    private func handle(_ event: WoonaV2Discovery.Event) {
        switch event {
        case .transmit(let wire): transmit(wire, requestID: discovery.pendingRequestID, discoveryCommand: true)
        case .complete(let device):
            cancelResponseTimer()
            let known = device.streams.descriptors.filter { (1...7).contains($0.id) }
            guard !known.isEmpty else { fail("No supported streams 1–7 were advertised"); return }
            snapshot.streams = known
            let mask = known.reduce(UInt32(0)) { $0 | (UInt32(1) << ($1.id - 1)) }
            snapshot.selectedMask = mask & 3 == 0 ? mask : mask & 3
            live = WoonaV2LiveSession(streams: device.streams); snapshot.stage = .ready
            snapshot.busySessionMode = nil; snapshot.reason = nil; publish()
        case .failure(let reason):
            snapshot.busySessionMode = discovery.lastStatus?.sessionMode
            fail(reason); publish()
        }
    }

    private func handle(_ event: WoonaV2LiveSession.Event) {
        switch event {
        case .transmit(let wire): transmit(wire, requestID: live?.pendingRequestID ?? 0, discoveryCommand: false)
        case .started:
            cancelResponseTimer(); snapshot.stage = .running; snapshot.reason = nil
            if !foreground { stopOwnLive() } // A late START_ACK still owns only our LIVE session.
            publish()
        case .stopped: cancelResponseTimer(); snapshot.stage = .stopped; snapshot.reason = nil; publish()
        case .failure(let reason): fail(reason); publish()
        case .samples(_, let block, let descriptor, let gap):
            snapshot.decodedBlocks += 1
            if gap { snapshot.wireGaps += 1 }
            guard foreground, (block.flags & 1) != 0 else {
                snapshot.skippedUIBlocks += 1; pendingBreaks.insert(block.streamID); return
            }
            if blocks.count == 64 {
                let omitted = blocks.removeFirst(); snapshot.skippedUIBlocks += 1
                pendingBreaks.insert(omitted.block.streamID)
            }
            blocks.append(PendingBlock(block: block, descriptor: descriptor, gap: gap))
        }
    }

    private func transmit(_ wire: Data, requestID: UInt32, discoveryCommand: Bool) {
        cancelResponseTimer()
        let identity = generation
        let writeToken = UUID(); timerToken = writeToken
        let writeDeadline = DispatchWorkItem { [weak self] in
            guard let self, self.connected, self.generation == identity, self.timerToken == writeToken,
                  requestID == (discoveryCommand ? self.discovery.pendingRequestID : self.live?.pendingRequestID ?? 0) else { return }
            self.fail("V2 ATT write acknowledgment timed out; command outcome is unknown. Keep the sensor connected or confirm Disconnect.")
            self.publish()
        }
        responseTimer = writeDeadline
        queue.asyncAfter(deadline: .now() + 8, execute: writeDeadline)
        Task { @MainActor [weak self] in
            guard let self else { return }
            write(identity, wire) { [weak self] result in
                guard let self else { return }
                queue.async { [self] in
                    guard connected, generation == identity,
                          requestID != 0,
                          requestID == (discoveryCommand ? discovery.pendingRequestID : live?.pendingRequestID ?? 0) else { return }
                    guard timerToken == writeToken else { return }
                    cancelResponseTimer()
                    switch result {
                    case .failure(let error): fail(error.localizedDescription); publish()
                    case .success: armResponseTimeout(requestID: requestID, discoveryCommand: discoveryCommand)
                    }
                }
            }
        }
    }

    private func armResponseTimeout(requestID: UInt32, discoveryCommand: Bool) {
        let identity = generation; let token = UUID(); timerToken = token
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.connected, self.generation == identity, self.timerToken == token,
                  requestID == (discoveryCommand ? self.discovery.pendingRequestID : self.live?.pendingRequestID ?? 0) else { return }
            if discoveryCommand { if let event = self.discovery.onResponseTimeout() { self.handle(event) } }
            else { if let event = self.live?.onResponseTimeout() { self.handle(event) } }
            self.publish()
        }
        responseTimer = timer
        queue.asyncAfter(deadline: .now() + 2, execute: timer)
    }

    private func cancelResponseTimer() { responseTimer?.cancel(); responseTimer = nil; timerToken = UUID() }
    private func cancelTimers() { cancelResponseTimer(); flushTimer?.cancel(); flushTimer = nil }
    private func fail(_ reason: String) { cancelResponseTimer(); snapshot.stage = .failed; snapshot.reason = reason }

    private func scheduleFlush() {
        guard foreground, flushTimer == nil else { return }
        let identity = generation
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.generation == identity else { return }
            self.flushTimer = nil; self.publish()
        }
        flushTimer = timer; queue.asyncAfter(deadline: .now() + 0.1, execute: timer)
    }

    private func publish() {
        guard !deliveryPending else { scheduleFlush(); return }
        if foreground {
            for pending in blocks { plot(pending) }
            blocks = []
            snapshot.channels = channels.values.sorted { $0.id < $1.id }
        }
        snapshot.rejectedFrames = decoder.rejectedFrames
        let value = snapshot; let identity = generation
        deliveryPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            update(identity, value)
            queue.async { [self] in deliveryPending = false }
        }
    }

    private func plot(_ pending: PendingBlock) {
        let block = pending.block; let descriptor = pending.descriptor
        guard (1...7).contains(block.streamID), block.rateHz > 0 else { snapshot.skippedUIBlocks += 1; return }
        if originUs == nil { originUs = block.timestampUs }
        guard let originUs, block.timestampUs >= originUs else {
            snapshot.skippedUIBlocks += 1; pendingBreaks.insert(block.streamID); return
        }
        let seconds = Double(block.timestampUs - originUs) / 1_000_000
        if let last = channels["\(block.streamID)-0"]?.points.last, seconds <= last.time {
            // Keep protocol acceptance separate from chart continuity. Do not
            // rewrite a backwards/overlapping source clock to fit the x-axis.
            snapshot.skippedUIBlocks += 1; pendingBreaks.insert(block.streamID); return
        }
        let bytes = [UInt8](block.samples)
        let breakBefore = pending.gap || pendingBreaks.remove(block.streamID) != nil
        for channel in 0..<descriptor.channels {
            let key = "\(block.streamID)-\(channel)"
            var series = channels[key] ?? V2PreviewChannel(streamID: block.streamID, channel: channel, points: [])
            for index in 0..<block.count {
                let offset = (index * descriptor.channels + channel) * 2
                let raw = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                let value = descriptor.format == 1 ? Double(Int16(bitPattern: raw)) : Double(raw)
                let time = seconds + Double(index) / Double(block.rateHz)
                let regression = series.points.last.map { time <= $0.time } ?? false
                series.points.append(V2PreviewPoint(time: time, value: value, breakBefore: (index == 0 && breakBefore) || regression))
            }
            if series.points.count > 6000 { series.points = Self.coarsen(series.points) }
            channels[key] = series
        }
    }

    // Preserve endpoints. When a skipped interval contains a segment boundary,
    // propagate that break to the next retained point rather than joining it.
    static func coarsen(_ points: [V2PreviewPoint]) -> [V2PreviewPoint] {
        guard points.count > 3000 else { return points }
        let stride = Int(ceil(Double(points.count - 1) / 2999))
        var output = [points[0]]; var breakPending = false
        for index in 1..<points.count {
            breakPending = breakPending || points[index].breakBefore
            if index % stride == 0 || index == points.count - 1 {
                var point = points[index]; point.breakBefore = point.breakBefore || breakPending
                output.append(point); breakPending = false
            }
        }
        return output
    }
}

@MainActor
final class V2PreviewController: ObservableObject {
    @Published private(set) var snapshot = V2PreviewSnapshot()
    private(set) var generation = UUID()
    var send: ((Data, @escaping @Sendable (Result<Void, Error>) -> Void) -> Void)?
    private(set) lazy var worker = V2PreviewWorker(update: { [weak self] generation, value in
        guard let self, self.generation == generation else { return }
        self.snapshot = value
    }, write: { [weak self] generation, wire, completion in
        guard let self, self.generation == generation, let send = self.send else {
            completion(.failure(BleControlWriteError.disconnected)); return
        }
        send(wire, completion)
    })
    func prepare() { generation = UUID(); worker.prepare(generation) }
    func ready() { worker.ready() }
    func select(mask: UInt32) { worker.select(mask: mask) }
    func start() { worker.start() }
    func stop() { worker.stop() }
    func setForeground(_ value: Bool) { worker.setForeground(value) }
    func disconnected(reason: String? = nil) { worker.disconnected(reason: reason) }
}
