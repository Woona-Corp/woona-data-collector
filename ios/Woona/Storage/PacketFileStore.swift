import Foundation

enum PacketFileStoreError: Error, Equatable {
    case closed
}

final class PacketFileStore {
    private let directory: URL
    private let filePrefix: String
    private let timestampProvider: () -> Int64
    private var currentFileURL: URL?
    private var fileHandle: FileHandle?
    private var writeBuffer: [UInt8] = []
    private var isClosed = false

    init(
        directory: URL,
        filePrefix: String = "ble_dump_",
        timestampProvider: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.directory = directory
        self.filePrefix = filePrefix
        self.timestampProvider = timestampProvider
    }

    func open() throws -> URL {
        guard !isClosed else { throw PacketFileStoreError.closed }
        if let currentFileURL, fileHandle != nil {
            return currentFileURL
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(filePrefix)\(timestampProvider()).bin")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        currentFileURL = fileURL
        fileHandle = handle
        return fileURL
    }

    func append(_ packetBytes: [UInt8]) throws {
        guard !packetBytes.isEmpty else { return }
        guard !isClosed else { throw PacketFileStoreError.closed }

        let handle = try ensureOpen()
        writeBuffer.append(contentsOf: packetBytes)
        if writeBuffer.count >= Self.bufferSizeBytes {
            try flushBuffer(to: handle)
        }
    }

    func flush() throws {
        guard !isClosed else { throw PacketFileStoreError.closed }
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
        guard !isClosed else { throw PacketFileStoreError.closed }
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
        guard !isClosed else { throw PacketFileStoreError.closed }
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
        if fileHandle == nil {
            _ = try open()
        }
        return fileHandle!
    }

    private func flushBuffer(to handle: FileHandle) throws {
        guard !writeBuffer.isEmpty else { return }
        try handle.write(contentsOf: Data(writeBuffer))
        writeBuffer.removeAll(keepingCapacity: true)
    }

    private static let bufferSizeBytes = 65_536
}
