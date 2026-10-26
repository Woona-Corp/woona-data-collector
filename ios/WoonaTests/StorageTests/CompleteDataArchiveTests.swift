import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import Woona

final class CompleteDataArchiveTests: XCTestCase {
    func testCompleteArchiveContainsHistoricalDatabaseLegacyOrphansPartialFilesAndMissingReferences() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try fixture(base)
        let nested = root.appendingPathComponent("recordings/собака/video.mp4.part")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data([0, 42, 255])
        try payload.write(to: nested)
        try Data("legacy".utf8).write(to: root.appendingPathComponent("ble_dump_old.bin"))
        let destination = base.appendingPathComponent("out.zip")
        _ = try CompleteDataArchive(dataDirectory: root).create(in: destination)
        let entries = try storedEntries(Data(contentsOf: destination))
        XCTAssertEqual(entries["data/Woona/recordings/собака/video.mp4.part"], payload)
        XCTAssertEqual(entries["data/Woona/ble_dump_old.bin"], Data("legacy".utf8))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(entries["manifest.json"])) as? [String: Any])
        let database = try XCTUnwrap(manifest["database"] as? [String: Any])
        XCTAssertEqual(database["unavailableLocalArtifactCount"] as? Int, 1)
        XCTAssertEqual((database["counts"] as? [String: Int])?["history"], 1)
        let snapshot = base.appendingPathComponent("readback.sqlite")
        try XCTUnwrap(entries["data/Woona/woona.sqlite"]).write(to: snapshot)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(snapshot.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT value FROM history", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "historic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testCancellationAndConcurrentMutationDiscardOnlyExport() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try fixture(base)
        let source = root.appendingPathComponent("video.mp4")
        try Data(repeating: 42, count: 2_000_000).write(to: source)
        let destination = base.appendingPathComponent("out.zip")
        var calls = 0
        XCTAssertThrowsError(try CompleteDataArchive(dataDirectory: root).create(in: destination, checkCancelled: {
            calls += 1
            if calls > 5 { throw CancellationError() }
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path))
        XCTAssertEqual(try Data(contentsOf: source).count, 2_000_000)
        XCTAssertThrowsError(try CompleteDataArchive(dataDirectory: root).create(in: destination, onProgress: { _ in
            try? Data("new".utf8).write(to: root.appendingPathComponent("new.bin"))
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testPathsSymlinksExistingDestinationsAndCredentialsAreSafe() throws {
        for name in ["../file", "/file", "a/../b", "a//b", "C:/file", "a\\b", "a\0b"] {
            XCTAssertThrowsError(try CompleteDataArchive.validateName(name))
        }
        XCTAssertTrue(CompleteDataArchive.legacyData("ble_dump_1.bin"))
        XCTAssertFalse(CompleteDataArchive.legacyData("connection-test.token"))
        XCTAssertFalse(CompleteDataArchive.legacyData("ble_old_export.zip"))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try fixture(base)
        let destination = base.appendingPathComponent("out.zip")
        try Data("existing".utf8).write(to: destination)
        XCTAssertThrowsError(try CompleteDataArchive(dataDirectory: root).create(in: destination))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing")
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("unsafe"), withDestinationURL: destination)
        XCTAssertThrowsError(try CompleteDataArchive(dataDirectory: root).create(in: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testInsufficientSpacePreservesOriginalAndDoesNotPublishArchive() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try fixture(base)
        let source = root.appendingPathComponent("large-video.mp4")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        let size: UInt64 = 2 * 1_024 * 1_024 * 1_024 * 1_024
        try handle.truncate(atOffset: size)
        try handle.close()
        let destination = base.appendingPathComponent("out.zip")
        XCTAssertThrowsError(try CompleteDataArchive(dataDirectory: root).create(in: destination)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Not enough free space"), error.localizedDescription)
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.uint64Value, size)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path))
    }

    private func fixture(_ base: URL) throws -> URL {
        let root = base.appendingPathComponent("Woona", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("woona.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE recordings(id TEXT PRIMARY KEY,status TEXT);
        CREATE TABLE artifacts(id TEXT,recording_id TEXT,relative_path TEXT,size_bytes INTEGER,sha256 TEXT);
        CREATE TABLE history(value TEXT);
        INSERT INTO recordings VALUES ('old','completed');
        INSERT INTO artifacts VALUES ('missing','old','recordings/server-only.mp4',99,'sha');
        INSERT INTO history VALUES ('historic');
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        return root
    }

    // Minimal independent reader for stored ZIP64 local records; compatibility with
    // Python's standard zipfile (including >65,535 entries) is checked by ios/tools.
    private func storedEntries(_ bytes: Data) throws -> [String: Data] {
        func unsigned(_ start: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(UInt64(0)) { $0 | UInt64(bytes[start + $1]) << ($1 * 8) }
        }
        var offset = 0
        var result: [String: Data] = [:]
        while offset + 30 <= bytes.count && unsigned(offset, 4) == 0x04034b50 {
            let nameSize = Int(unsigned(offset + 26, 2))
            let extraSize = Int(unsigned(offset + 28, 2))
            let name = String(decoding: bytes[(offset + 30)..<(offset + 30 + nameSize)], as: UTF8.self)
            let size = Int(unsigned(offset + 30 + nameSize + 4, 8))
            let dataStart = offset + 30 + nameSize + extraSize
            guard dataStart + size + 24 <= bytes.count else { throw WoonaStoreError.invalidData("Invalid ZIP length") }
            result[name] = bytes.subdata(in: dataStart..<(dataStart + size))
            XCTAssertEqual(unsigned(dataStart + size, 4), 0x08074b50)
            offset = dataStart + size + 24
        }
        XCTAssertEqual(unsigned(offset, 4), 0x02014b50)
        return result
    }
}
