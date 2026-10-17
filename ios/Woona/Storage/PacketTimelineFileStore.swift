import Foundation

final class PacketTimelineFileStore {
    static let magicHeader = Array("BLETIME1".utf8)
    private let directory: URL
    private var fileURL: URL?
    private var handle: FileHandle?
    private var buffer: [UInt8] = []
    private var closed = false

    init(directory: URL) { self.directory = directory }

    func append(sequence: Int64, counter: Int64, deviceTimerMillis: Int64, hostWallClockMillis: Int64, hostMonotonicNs: Int64, packetBytes: Int32) throws {
        let handle = try ensureOpen()
        buffer.appendBigEndianInt64(sequence)
        buffer.appendBigEndianInt64(counter)
        buffer.appendBigEndianInt64(deviceTimerMillis)
        buffer.appendBigEndianInt64(hostWallClockMillis)
        buffer.appendBigEndianInt64(hostMonotonicNs)
        buffer.appendBigEndianInt32(packetBytes)
        if buffer.count >= 65_536 { try flushBuffer(to: handle) }
    }

    func flush() throws { if let handle { try flushBuffer(to: handle); try handle.synchronize() } }
    func resetSession() throws { try flush(); try handle?.close(); handle = nil; fileURL = nil }
    func closeCurrentSession() throws {
        let currentHandle = handle
        defer {
            handle = nil
            buffer.removeAll(keepingCapacity: true)
        }
        do { try flush() }
        catch {
            try? currentHandle?.close()
            throw error
        }
        try currentHandle?.close()
    }
    func close() throws { guard !closed else { return }; defer { closed = true }; try closeCurrentSession() }
    func currentFile() -> URL? { fileURL }
    func hasOpenFileHandle() -> Bool { handle != nil }

    private func ensureOpen() throws -> FileHandle {
        if let handle { return handle }
        guard !closed else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("packet_timeline.bin")
        FileManager.default.createFile(atPath: url.path, contents: Data(Self.magicHeader))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.handle = handle
        fileURL = url
        return handle
    }

    private func flushBuffer(to handle: FileHandle) throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: Data(buffer))
        buffer.removeAll(keepingCapacity: true)
    }
}
