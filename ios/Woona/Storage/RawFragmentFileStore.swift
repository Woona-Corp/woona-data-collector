import Foundation

enum RawFragmentFileStoreError: Error, Equatable {
    case closed
}

final class RawFragmentFileStore {
    static let magicHeader: [UInt8] = [0x42, 0x4C, 0x45, 0x52, 0x41, 0x57, 0x32, 0x00]
    static let legacyMagicHeader: [UInt8] = [0x42, 0x4C, 0x45, 0x52, 0x41, 0x57, 0x31, 0x00]

    private let directory: URL
    private let filePrefix: String
    private let timestampProvider: () -> Int64
    private var currentFileURL: URL?
    private var fileHandle: FileHandle?
    private var writeBuffer: [UInt8] = []
    private var isClosed = false

    init(
        directory: URL,
        filePrefix: String = "ble_raw_",
        timestampProvider: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.directory = directory
        self.filePrefix = filePrefix
        self.timestampProvider = timestampProvider
    }

    func appendFragment(
        sequence: Int64,
        receivedAtMillis: Int64,
        receivedAtMonotonicNs: Int64 = 0,
        fragmentBytes: [UInt8]
    ) throws {
        guard !fragmentBytes.isEmpty else { return }
        guard !isClosed else { throw RawFragmentFileStoreError.closed }

        let handle = try ensureOpen()
        writeBuffer.reserveCapacity(writeBuffer.count + 28 + fragmentBytes.count)
        writeBuffer.appendBigEndianInt64(sequence)
        writeBuffer.appendBigEndianInt64(receivedAtMillis)
        writeBuffer.appendBigEndianInt64(receivedAtMonotonicNs)
        writeBuffer.appendBigEndianInt32(Int32(fragmentBytes.count))
        writeBuffer.append(contentsOf: fragmentBytes)
        if writeBuffer.count >= Self.bufferSizeBytes {
            try flushBuffer(to: handle)
        }
    }

    func flush() throws {
        guard !isClosed else { throw RawFragmentFileStoreError.closed }
        if let fileHandle {
            try flushBuffer(to: fileHandle)
        }
        try fileHandle?.synchronize()
    }

    func close() throws {
        guard !isClosed else { return }
        defer { isClosed = true }
        try closeCurrentSession()
    }

    func closeCurrentSession() throws {
        guard !isClosed else { throw RawFragmentFileStoreError.closed }
        let handle = fileHandle
        defer {
            fileHandle = nil
            writeBuffer.removeAll(keepingCapacity: true)
        }
        do { try flush() }
        catch {
            try? handle?.close()
            throw error
        }
        try handle?.close()
    }

    func resetSession() throws {
        guard !isClosed else { throw RawFragmentFileStoreError.closed }
        try flush()
        try fileHandle?.close()
        fileHandle = nil
        currentFileURL = nil
    }

    func currentFile() -> URL? {
        currentFileURL
    }

    func hasOpenFileHandle() -> Bool {
        fileHandle != nil
    }

    private func ensureOpen() throws -> FileHandle {
        if let fileHandle {
            return fileHandle
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(filePrefix)\(timestampProvider()).binlog")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(Self.magicHeader))
        currentFileURL = fileURL
        fileHandle = handle
        return handle
    }

    private func flushBuffer(to handle: FileHandle) throws {
        guard !writeBuffer.isEmpty else { return }
        try handle.write(contentsOf: Data(writeBuffer))
        writeBuffer.removeAll(keepingCapacity: true)
    }

    private static let bufferSizeBytes = 4_096
}

extension Array where Element == UInt8 {
    mutating func appendBigEndianInt64(_ value: Int64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndianInt32(_ value: Int32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
