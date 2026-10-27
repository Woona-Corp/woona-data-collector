import Foundation

enum BleControlWriteError: LocalizedError {
    case invalidFrame, invalidChunkLimit, queueFull, disconnected, characteristicUnavailable, writeUnsupported

    var errorDescription: String? {
        switch self {
        case .invalidFrame: return "V2 control frame is empty or exceeds 2082 wire bytes"
        case .invalidChunkLimit: return "CoreBluetooth did not provide a positive ATT write size"
        case .queueFull: return "V2 control queue reached its four-frame limit"
        case .disconnected: return "V2 control connection was closed"
        case .characteristicUnavailable: return "Woona FFF2 control characteristic is unavailable"
        case .writeUnsupported: return "Woona FFF2 does not support acknowledged ATT writes"
        }
    }
}

/// Confined to the CoreBluetooth serial queue. One acknowledged ATT fragment
/// is in flight; a frame completes only after its final fragment's callback.
/// Four full 2082-byte frames bound pending control memory to about 8 KiB.
final class BleControlWriteQueue {
    typealias Completion = @Sendable (Result<Void, Error>) -> Void

    private final class Frame {
        let data: Data
        let maximumChunkBytes: Int
        let completion: Completion
        var offset = 0

        init(data: Data, maximumChunkBytes: Int, completion: @escaping Completion) {
            self.data = data; self.maximumChunkBytes = maximumChunkBytes; self.completion = completion
        }
    }

    private var frames: [Frame] = []
    private var awaitingBytes = 0
    var pendingFrameCount: Int { frames.count }
    var isAwaitingAcknowledgment: Bool { awaitingBytes > 0 }

    func enqueue(_ data: Data, maximumChunkBytes: Int, completion: @escaping Completion) throws {
        guard !data.isEmpty, data.count <= 2082 else { throw BleControlWriteError.invalidFrame }
        guard maximumChunkBytes > 0 else { throw BleControlWriteError.invalidChunkLimit }
        guard frames.count < 4 else { throw BleControlWriteError.queueFull }
        frames.append(Frame(data: data, maximumChunkBytes: maximumChunkBytes, completion: completion))
    }

    func nextFragment() -> Data? {
        guard awaitingBytes == 0, let frame = frames.first else { return nil }
        let count = min(frame.maximumChunkBytes, frame.data.count - frame.offset)
        guard count > 0 else { return nil }
        awaitingBytes = count
        let start = frame.data.startIndex + frame.offset
        return frame.data.subdata(in: start..<(start + count))
    }

    func acknowledge(error: Error? = nil) {
        guard awaitingBytes > 0, let frame = frames.first else { return }
        if let error { reset(error: error); return }
        frame.offset += awaitingBytes
        awaitingBytes = 0
        if frame.offset == frame.data.count {
            frames.removeFirst()
            frame.completion(.success(()))
        }
    }

    func reset(error: Error = BleControlWriteError.disconnected) {
        let interrupted = frames
        frames = []; awaitingBytes = 0
        for frame in interrupted { frame.completion(.failure(error)) }
    }
}
