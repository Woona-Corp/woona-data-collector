import CryptoKit
import Foundation
import SQLite3

/// A streaming ZIP64 archive of available app data. Authentication stores are never traversed.
struct CompleteDataArchive: Sendable {
    struct Root: Sendable {
        let prefix: String
        let directory: URL
        var legacyOnly = false
    }
    struct Progress: Sendable {
        let completedBytes: UInt64
        let totalBytes: UInt64
        let completedFiles: Int
        let totalFiles: Int
    }
    private struct Source: Equatable {
        let name: String
        let sourcePath: String
        let url: URL
        let size: UInt64
        let modified: Date
        let inode: UInt64
    }
    let dataDirectory: URL
    var additionalRoots: [Root] = []
    var configuration: [String: String] = [:]

    func create(in destination: URL, checkCancelled: () throws -> Void = { try Task.checkCancellation() }, onProgress: (Progress) -> Void = { _ in }) throws -> URL {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let roots = [Root(prefix: "data/Woona", directory: dataDirectory)] + additionalRoots
        for root in roots {
            let path = root.directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard !destination.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(path) else { throw completeArchiveError("Archive must be outside the data being exported") }
        }
        guard !manager.fileExists(atPath: destination.path) else { throw completeArchiveError("Archive destination already exists") }
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("part")
        let snapshot = parent.appendingPathComponent("snapshot-\(UUID().uuidString).sqlite")
        guard !manager.fileExists(atPath: partial.path) else { throw completeArchiveError("Partial archive destination already exists") }
        defer { try? manager.removeItem(at: snapshot) }
        let database = try Database(dataDirectory.appendingPathComponent("woona.sqlite"), writable: false)
        let version = try database.scalar("PRAGMA data_version")
        guard try database.scalar("SELECT count(*) FROM recordings WHERE status IN ('preparing','recording')") == 0 else {
            throw completeArchiveError("Stop and finalize the active recording before exporting all data. Original data is unchanged.")
        }
        try database.snapshot(to: snapshot, checkCancelled: checkCancelled)
        var metadata = try Database(snapshot, writable: false).metadata(root: dataDirectory)
        metadata["configuration"] = configuration
        let initial = try inventory(roots)
        let sources = [try source(name: "data/Woona/woona.sqlite", url: snapshot)] + initial
        guard Set(sources.map(\.name)).count == sources.count else { throw completeArchiveError("Duplicate archive entry") }
        let total = try sources.reduce(UInt64(0)) { value, source in
            let (sum, overflow) = value.addingReportingOverflow(source.size)
            guard !overflow else { throw completeArchiveError("Data size exceeds the archive's 64-bit limit. Original data is unchanged.") }
            return sum
        }
        let free = (try manager.attributesOfFileSystem(forPath: parent.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        let (required, sizeOverflow) = total.addingReportingOverflow(16 * 1_024 * 1_024 + UInt64(sources.count) * 1_024)
        guard !sizeOverflow else { throw completeArchiveError("Not enough addressable space for the archive. Original data is unchanged.") }
        guard free >= required else { throw completeArchiveError("Not enough free space: approximately \(required) bytes needed, \(free) bytes available. Original data is unchanged.") }
        do {
            let zip = try StreamingZIP64(partial)
            var completed: UInt64 = 0
            var entries: [[String: Any]] = []
            for item in sources {
                try checkCancelled()
                guard try source(name: item.name, url: item.url, sourcePath: item.sourcePath) == item else { throw completeArchiveError("Data changed during export: \(item.name). Retry after recording and transfers finish.") }
                let handle = try FileHandle(forReadingFrom: item.url)
                defer { try? handle.close() }
                var digest = SHA256()
                var count: UInt64 = 0
                try zip.add(name: item.name, size: item.size) {
                    try checkCancelled()
                    let bytes = try handle.read(upToCount: 65_536) ?? Data()
                    if !bytes.isEmpty {
                        digest.update(data: bytes)
                        count += UInt64(bytes.count)
                        completed += UInt64(bytes.count)
                        onProgress(.init(completedBytes: completed, totalBytes: total, completedFiles: entries.count, totalFiles: sources.count))
                    }
                    return bytes
                }
                guard count == item.size, try source(name: item.name, url: item.url, sourcePath: item.sourcePath) == item else { throw completeArchiveError("Data changed during export: \(item.name). Original data is safe; retry after transfers finish.") }
                entries.append(["path": item.name, "sourcePath": item.sourcePath, "sizeBytes": count, "sha256": digest.finalize().map { String(format: "%02x", $0) }.joined()])
                onProgress(.init(completedBytes: completed, totalBytes: total, completedFiles: entries.count, totalFiles: sources.count))
            }
            guard try inventory(roots) == initial else { throw completeArchiveError("Files changed during export. Original data is safe; retry after recording and transfers finish.") }
            for item in sources { guard try source(name: item.name, url: item.url, sourcePath: item.sourcePath) == item else { throw completeArchiveError("Data changed during export. Retry after transfers finish.") } }
            guard try database.scalar("PRAGMA data_version") == version else { throw completeArchiveError("Local database changed during export. Wait for editing and synchronization to finish, then retry. Original data is safe.") }
            let manifest: [String: Any] = [
                "format": "woona-complete-data-archive", "schemaVersion": 1, "platform": "ios", "createdAtUtc": ISO8601DateFormatter().string(from: Date()),
                "scope": "All app-owned local data still available at export time, across every account and animal. This is not a server backup.",
                "limitations": ["Physically deleted files and data from another installation or device cannot be recovered by this export.", "Server-only artifacts are listed as unavailable locally; export does not download or delete them.", "Authentication tokens, Keychain, preferences containing credentials, previous export archives and transient operating-system caches are excluded."],
                "database": metadata, "files": entries, "fileCount": entries.count, "totalBytes": total,
            ]
            let bytes = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            var pending = bytes
            try zip.add(name: "manifest.json", size: UInt64(bytes.count)) { defer { pending = Data() }; return pending }
            try checkCancelled()
            try zip.finish()
            try manager.moveItem(at: partial, to: destination)
            return destination
        } catch {
            try? manager.removeItem(at: partial)
            throw error
        }
    }

    private func inventory(_ roots: [Root]) throws -> [Source] {
        var values: [Source] = []
        for root in roots {
            try Self.validateName(root.prefix)
            guard FileManager.default.fileExists(atPath: root.directory.path) else { continue }
            let base = root.directory.resolvingSymlinksInPath().standardizedFileURL
            guard try root.directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw completeArchiveError("Symbolic data root is not exportable") }
            func visit(_ directory: URL) throws {
                for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).sorted(by: { $0.path < $1.path }) {
                    let relative = String(child.path.dropFirst(base.path.count + 1))
                    if root.prefix == "data/Woona", ["woona.sqlite", "woona.sqlite-wal", "woona.sqlite-shm", "woona.sqlite-journal"].contains(relative) { continue }
                    if root.legacyOnly && !Self.legacyData(relative) { continue }
                    let properties = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard properties.isSymbolicLink != true, child.resolvingSymlinksInPath().path.hasPrefix(base.path + "/") else { throw completeArchiveError("Symbolic link or escaping path is not exportable: \(relative)") }
                    if properties.isDirectory == true { try visit(child) }
                    else { values.append(try source(name: root.prefix + "/" + Self.portablePath(relative), url: child, sourcePath: root.prefix + "/" + relative)) }
                }
            }
            try visit(base)
        }
        return values.sorted { $0.name < $1.name }
    }

    private func source(name: String, url: URL, sourcePath: String? = nil) throws -> Source {
        try Self.validateName(name)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber else { throw completeArchiveError("Not a regular data file: \(name)") }
        return Source(name: name, sourcePath: sourcePath ?? name, url: url, size: size.uint64Value, modified: modified, inode: inode.uint64Value)
    }

    static func validateName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"), !name.contains(":"),
              !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), name.utf8.count <= 65_535 else { throw completeArchiveError("Unsafe archive path") }
    }
    static func portablePath(_ relative: String) -> String {
        relative.unicodeScalars.map { scalar in
            if scalar.value < 32 || "%<>:\"\\|?*".unicodeScalars.contains(scalar) { return String(format: "%%%02X", scalar.value) }
            return String(scalar)
        }.joined()
    }
    static func legacyData(_ relative: String) -> Bool {
        !relative.contains("/") && ["ble_", "polar_", "debug-replay-"].contains(where: relative.hasPrefix) &&
        ["bin", "binlog", "log", "csv", "json", "mp4", "part", "tmp"].contains((relative as NSString).pathExtension.lowercased())
    }

    private final class Database {
        private var handle: OpaquePointer?
        init(_ url: URL, writable: Bool) throws {
            let flags = (writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
                sqlite3_close(handle); handle = nil
                throw completeArchiveError("Unable to open local SQLite database for export")
            }
            sqlite3_busy_timeout(handle, 5_000)
        }
        deinit { sqlite3_close(handle) }
        func query(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
            defer { sqlite3_finalize(statement) }
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw error() }
                try body(statement)
            }
        }
        func scalar(_ sql: String) throws -> Int64 {
            var value: Int64 = 0
            try query(sql) { value = sqlite3_column_int64($0, 0) }
            return value
        }
        func snapshot(to url: URL, checkCancelled: () throws -> Void) throws {
            let target = try Database(url, writable: true)
            guard let backup = sqlite3_backup_init(target.handle, "main", handle, "main") else { throw target.error() }
            defer { sqlite3_backup_finish(backup) }
            let deadline = Date().addingTimeInterval(30)
            while true {
                try checkCancelled()
                let result = sqlite3_backup_step(backup, 256)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED else { throw target.error() }
                guard Date() < deadline else { throw completeArchiveError("Database is busy. Wait for synchronization to finish, then retry export.") }
                if result != SQLITE_OK { sqlite3_sleep(20) }
            }
        }
        func metadata(root: URL) throws -> [String: Any] {
            var integrity = ""
            try query("PRAGMA quick_check") { integrity = String(cString: sqlite3_column_text($0, 0)) }
            guard integrity == "ok" else { throw completeArchiveError("SQLite snapshot failed its integrity check") }
            var names: [String] = []
            try query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name") { names.append(String(cString: sqlite3_column_text($0, 0))) }
            var counts: [String: Int64] = [:]
            for table in names { counts[table] = try scalar("SELECT count(*) FROM \"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\"") }
            var missing: [[String: Any]] = []
            try query("SELECT id,recording_id,relative_path,size_bytes,sha256 FROM artifacts ORDER BY relative_path") { statement in
                func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
                let relative = text(2)
                let file = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
                guard file.path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw completeArchiveError("Artifact path escapes local data root") }
                if !FileManager.default.fileExists(atPath: file.path) {
                    missing.append(["artifactId": text(0), "recordingId": text(1), "path": "data/Woona/" + relative, "expectedBytes": sqlite3_column_int64(statement, 3), "expectedSha256": text(4), "reason": "not_available_locally_deleted_or_server_only"])
                }
            }
            return ["snapshot": "data/Woona/woona.sqlite", "integrityCheck": "ok", "counts": counts, "unavailableLocalArtifacts": missing, "unavailableLocalArtifactCount": missing.count]
        }
        private func error() -> WoonaStoreError { .sqlite(String(cString: sqlite3_errmsg(handle))) }
    }
}

/// ZIP64 + UTF-8 + data descriptors; stores file bytes directly with bounded memory.
/// A central directory uses 64-bit sizes and offsets even for small files, so large videos work.
final class StreamingZIP64 {
    private struct Entry { let name: Data; let size: UInt64; let crc: UInt32; let offset: UInt64 }
    private let handle: FileHandle
    private var position: UInt64 = 0
    private var entries: [Entry] = []
    private var entryNames = Set<String>()
    private var finished = false
    init(_ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw WoonaStoreError.invalidData("Cannot create archive") }
        handle = try FileHandle(forWritingTo: url)
    }
    deinit { try? handle.close() }
    func add(name: String, size: UInt64, read: () throws -> Data) throws {
        try CompleteDataArchive.validateName(name)
        guard !finished, !entryNames.contains(name) else { throw WoonaStoreError.invalidData("Duplicate or closed ZIP entry") }
        entryNames.insert(name)
        let filename = Data(name.utf8)
        let start = position
        var local = Data()
        local.le32(0x04034b50); local.le16(45); local.le16(0x0808); local.le16(0); local.le16(0); local.le16(0x0021)
        local.le32(0); local.le32(.max); local.le32(.max); local.le16(UInt16(filename.count)); local.le16(20)
        local.append(filename); local.le16(1); local.le16(16); local.le64(size); local.le64(size)
        try write(local)
        var crc: UInt32 = .max
        var actual: UInt64 = 0
        while true {
            let data = try read()
            if data.isEmpty { break }
            actual += UInt64(data.count)
            guard actual <= size else { throw WoonaStoreError.invalidData("File grew during archive export") }
            crc = Self.updateCRC(crc, data)
            try write(data)
        }
        guard actual == size else { throw WoonaStoreError.invalidData("File shrank during archive export") }
        crc ^= .max
        var descriptor = Data()
        descriptor.le32(0x08074b50); descriptor.le32(crc); descriptor.le64(size); descriptor.le64(size)
        try write(descriptor)
        entries.append(Entry(name: filename, size: size, crc: crc, offset: start))
    }
    func finish() throws {
        guard !finished else { return }
        let centralStart = position
        for item in entries {
            var data = Data()
            data.le32(0x02014b50); data.le16(45); data.le16(45); data.le16(0x0808); data.le16(0); data.le16(0); data.le16(0x0021)
            data.le32(item.crc); data.le32(.max); data.le32(.max); data.le16(UInt16(item.name.count)); data.le16(28); data.le16(0)
            data.le16(0); data.le16(0); data.le32(0); data.le32(.max); data.append(item.name)
            data.le16(1); data.le16(24); data.le64(item.size); data.le64(item.size); data.le64(item.offset)
            try write(data)
        }
        let centralSize = position - centralStart
        let endStart = position
        var footer = Data()
        footer.le32(0x06064b50); footer.le64(44); footer.le16(45); footer.le16(45); footer.le32(0); footer.le32(0)
        footer.le64(UInt64(entries.count)); footer.le64(UInt64(entries.count)); footer.le64(centralSize); footer.le64(centralStart)
        footer.le32(0x07064b50); footer.le32(0); footer.le64(endStart); footer.le32(1)
        footer.le32(0x06054b50); footer.le16(0); footer.le16(0); footer.le16(.max); footer.le16(.max); footer.le32(.max); footer.le32(.max); footer.le16(0)
        try write(footer)
        try handle.synchronize()
        try handle.close()
        finished = true
    }
    private func write(_ data: Data) throws { try handle.write(contentsOf: data); position += UInt64(data.count) }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
    private static func updateCRC(_ initial: UInt32, _ data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes in
            var crc = initial
            for byte in bytes.bindMemory(to: UInt8.self) { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
            return crc
        }
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { var v = value.littleEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
    mutating func le32(_ value: UInt32) { var v = value.littleEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
    mutating func le64(_ value: UInt64) { var v = value.littleEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
}

private func completeArchiveError(_ message: String) -> WoonaStoreError { .invalidData(message) }
