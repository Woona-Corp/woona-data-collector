import XCTest
@testable import Woona

final class SyncActivityLogTests: XCTestCase {
    private let id = "10000000-0000-0000-0000-000000000001"

    private func event(_ n: Int = 0, kind: String = "recording", outcome: String = "started") -> SyncActivityEvent {
        SyncActivityEvent(timestampUtc: String(format: "2026-11-07T12:00:00.%03dZ", n),
            entityKind: kind, entityId: id, action: "upload", outcome: outcome, code: nil)
    }

    func testCapAndRecentKeepActualNewestMatchingVersionAndKind() {
        let events = (0..<200).map { event($0) }
        XCTAssertEqual(SyncActivityLog.capped(events), Array(events.suffix(128)))
        XCTAssertEqual(SyncActivityLog.filterRecent(events, kind: "recording", id: id),
                       Array(events.reversed().prefix(20)))
        XCTAssertEqual(SyncActivityLog.filterRecent(events, kind: "recording", id: id, limit: 999).count, 128)
        XCTAssertTrue(SyncActivityLog.filterRecent(events, kind: "recording", id: id, limit: -1).isEmpty)
        XCTAssertTrue(SyncActivityLog.filterRecent(events, kind: "profile", id: id).isEmpty)
        XCTAssertTrue(SyncActivityLog.filterRecent(events, kind: "recording", id: UUID().uuidString).isEmpty)
        XCTAssertTrue(SyncActivityLog.capped([]).isEmpty)
    }

    func testNoFreeTextOrTokensAllowedInCodesActionsOrIds() {
        for raw in ["Bearer synthetic-secret", "{\"token\":\"synthetic\"}", "http_999", String(repeating: "x", count: 500)] {
            XCTAssertNil(SyncActivityLog.safeCode(raw))
            XCTAssertFalse(SyncActivityLog.isSafe(SyncActivityEvent(timestampUtc: event().timestampUtc,
                entityKind: "recording", entityId: id, action: raw, outcome: "failed", code: nil)))
            XCTAssertFalse(SyncActivityLog.isSafe(SyncActivityEvent(timestampUtc: event().timestampUtc,
                entityKind: "recording", entityId: raw, action: "upload", outcome: "failed", code: nil)))
            XCTAssertFalse(SyncActivityLog.isSafe(SyncActivityEvent(timestampUtc: event().timestampUtc,
                entityKind: "recording", entityId: id, action: "upload", outcome: "failed", code: raw)))
        }
        XCTAssertEqual(SyncActivityLog.safeCode("http_409"), "http_409")
        XCTAssertEqual(SyncActivityLog.safeCode("offline"), "offline")
        XCTAssertFalse(SyncActivityLog.isSafe(event(kind: "raw JSON")))
        XCTAssertFalse(SyncActivityLog.isSafe(event(outcome: "arbitrary error message")))
    }

    func testCorruptRowsAreIgnoredSafeRowsPreservedAndUnsafeCodeRemoved() throws {
        let row: [String: Any] = ["timestampUtc": event().timestampUtc, "entityKind": "recording",
            "entityId": id, "action": "upload", "outcome": "started", "code": "Bearer synthetic-secret"]
        let data = try JSONSerialization.data(withJSONObject: [row, "bad row", ["action": "bad"]])
        XCTAssertEqual(SyncActivityLog.decode(data), [event()])
        XCTAssertTrue(SyncActivityLog.decode(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(SyncActivityLog.decode(Data(repeating: 120, count: SyncActivityLog.maxJSONBytes + 1)).isEmpty)
    }

    func testActualEventsPersistAcrossInstancesAndDoNotStoreUnsafeDiagnostics() throws {
        let suite = "SyncActivityLogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = SyncActivityLog(defaults: defaults)
        XCTAssertTrue(log.recent(kind: "recording", id: id).isEmpty)
        log.record(kind: "recording", id: id, action: .upload, outcome: .started,
                   code: "Bearer synthetic-private-token")
        waitForCount(1, log: log)
        let first = try XCTUnwrap(log.recent(kind: "recording", id: id).first)
        log.record(kind: "recording", id: id, action: .upload, outcome: .succeeded)
        waitForCount(2, log: log)
        let reopened = SyncActivityLog(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let events = reopened.recent(kind: "recording", id: id)
        XCTAssertEqual(events.map(\.outcome), ["succeeded", "started"])
        XCTAssertEqual(events.last?.timestampUtc, first.timestampUtc)
        let bytes = try XCTUnwrap(defaults.data(forKey: SyncActivityLog.preferenceKey))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("synthetic-private-token"))
    }

    func testAppendRepairsCorruptStorageAndCapsPersistedJournal() throws {
        let suite = "SyncActivityLogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let persisted = expectation(description: "Final http_409 journal write completed")
        let observedDefaults = try XCTUnwrap(PersistObservationSyncActivityDefaults(suiteName: suite, persisted: persisted))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = SyncActivityLog(defaults: observedDefaults)
        defaults.set(Data("broken JSON".utf8), forKey: SyncActivityLog.preferenceKey)
        XCTAssertTrue(log.recent(kind: "recording", id: id).isEmpty)
        log.record(kind: "recording", id: id, action: .localSaved, outcome: .succeeded)
        waitForCount(1, log: log)
        XCTAssertEqual(log.recent(kind: "recording", id: id).first?.action, "local_saved")
        defaults.set(try JSONEncoder().encode((0..<128).map { event($0) }), forKey: SyncActivityLog.preferenceKey)
        log.record(kind: "recording", id: id, action: .upload, outcome: .succeeded, code: "http_409")
        // Observe the actual write without polling recent(), which takes the
        // same IO lock needed by the utility-priority writer.
        wait(for: [persisted], timeout: 5)
        let events = log.recent(kind: "recording", id: id, limit: 999)
        XCTAssertEqual(events.count, 128)
        XCTAssertEqual(events.first?.outcome, "succeeded")
        XCTAssertEqual(events.first?.code, "http_409")
    }

    func testStalledPreferenceWriteDoesNotBlockAdmissionOfNextActualEvent() throws {
        let suite = "SyncActivityLogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(BlockingSyncActivityDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = SyncActivityLog(defaults: defaults)
        log.record(kind: "recording", id: id, action: .upload, outcome: .started)
        XCTAssertEqual(defaults.writeStarted.wait(timeout: .now() + 5), .success)
        // The first writer holds the storage lock and cannot progress until this
        // test releases it. A second admission must complete independently.
        let admitted = DispatchSemaphore(value: 0)
        let entityID = id
        DispatchQueue.global().async {
            log.record(kind: "recording", id: entityID, action: .upload, outcome: .succeeded)
            admitted.signal()
        }
        let result = admitted.wait(timeout: .now() + 1)
        defaults.releaseWrite.signal()
        XCTAssertEqual(result, .success, "record waited behind stalled preference IO")
        waitForCount(2, log: log)
    }

    func testBilingualLabelsAndUnknownValueDoesNotEchoUnsafeText() {
        XCTAssertEqual(syncActivityActionLabel("check_delivery", russian: true), "Проверка доставки")
        XCTAssertEqual(syncActivityActionLabel("local_saved", russian: false), "Local save")
        XCTAssertEqual(syncActivityOutcomeLabel("waiting_network", russian: false), "Waiting for network")
        XCTAssertEqual(syncActivityOutcomeLabel("succeeded", russian: true), "Успешно")
        XCTAssertEqual(syncActivityActionLabel("Bearer synthetic", russian: false), "Unknown action")
        XCTAssertEqual(syncActivityOutcomeLabel("raw JSON", russian: true), "Неизвестный результат")
    }

    func testDiagnosticRedactionIsIdempotentAcrossStorageAndPresentation() {
        for raw in [
            "Authorization: Bearer private-fixture",
            "Authorization: Basic private-fixture",
            #"{"token":"private-fixture","Authorization":"Bearer private-fixture"}"#,
            "https://user:private-fixture@host/path?unknown=private-fixture#private-fixture",
            "Bearer private-fixture"
        ] {
            let once = safeSyncDiagnostic(raw)
            XCTAssertEqual(safeSyncDiagnostic(once), once)
            XCTAssertFalse(once.contains("private-fixture"))
        }
    }

    func testDiagnosticRedactionRemovesAllURLValuesAndKnownCredentials() {
        let raw = """
        HTTP 409 requestId=req-fixture
        aUtHoRiZaTiOn:
          BeArEr sentinel-auth
        {"apiKey":"sentinel-api","PASSWORD":"sentinel-password","refresh_token":"sentinel-refresh"}
        https://user:sentinel-user@host.test/path?X-AmZ-Signature=sentinel-sign&unknown=sentinel-unknown#sentinel-fragment
        HTTPS://host.test/path%3Funknown%3Dsentinel-encoded%23sentinel-hash
        https%3A%2F%2Fuser:sentinel-user%40host.test/path%3Fkey%3Dsentinel-full
        Authorization: Basic sentinel-basic
        reflected sentinel-configured
        """
        let text = safeSyncDiagnostic(raw, secret: "sentinel-configured")
        XCTAssertFalse(text.contains("sentinel"))
        XCTAssertTrue(text.contains("host.test/path"))
        XCTAssertTrue(text.contains("HTTP 409 requestId=req-fixture"))
    }

    func testHTTPErrorSanitizesConfiguredTokenBeforePersistenceAndKeepsCodeAndRequestID() throws {
        let body = Data(#"{"detail":{"code":"server_busy","message":"reflected sentinel-configured https://host.test/path?unknown=sentinel-query#sentinel-fragment","requestId":"req-fixture"}}"#.utf8)
        let error = ServerSyncError.responseError(status: 503, data: body, secret: "sentinel-configured")
        guard case .requestFailed(let status, let message) = error else { return XCTFail("Expected HTTP error") }
        XCTAssertEqual(status, 503)
        XCTAssertFalse(message.contains("sentinel"))
        XCTAssertTrue(message.contains("server_busy"))
        XCTAssertTrue(message.contains("req-fixture"))
        let conflict = ServerSyncError.responseError(status: 409,
            data: Data(#"{"detail":{"code":"animal_id_already_exists","message":"sentinel-configured"}}"#.utf8),
            secret: "sentinel-configured")
        guard case .animalIDConflict = conflict else { return XCTFail("Expected actionable identity conflict") }
    }

    private func waitForCount(_ count: Int, log: SyncActivityLog,
                              file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if log.recent(kind: "recording", id: id, limit: 128).count == count { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("Journal did not reach \(count) actual events", file: file, line: line)
    }
}

/// Observe real preference persistence without contending for the journal's read/IO lock.
private final class PersistObservationSyncActivityDefaults: UserDefaults, @unchecked Sendable {
    private let persisted: XCTestExpectation
    private var observed = false // only the final journal writer matches the marker

    init?(suiteName: String, persisted: XCTestExpectation) {
        self.persisted = persisted
        super.init(suiteName: suiteName)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        guard defaultName == SyncActivityLog.preferenceKey, let data = value as? Data,
              let last = (try? JSONDecoder().decode([SyncActivityEvent].self, from: data))?.last,
              last.action == "upload", last.outcome == "succeeded", last.code == "http_409",
              !observed else { return }
        observed = true
        persisted.fulfill()
    }
}

/// Inject a stalled first disk write without a production storage abstraction.
private final class BlockingSyncActivityDefaults: UserDefaults, @unchecked Sendable {
    let writeStarted = DispatchSemaphore(value: 0)
    let releaseWrite = DispatchSemaphore(value: 0)
    private var firstWrite = true // accessed only on the journal's serial writer

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == SyncActivityLog.preferenceKey && firstWrite {
            firstWrite = false
            writeStarted.signal()
            _ = releaseWrite.wait(timeout: .now() + 10)
        }
        super.set(value, forKey: defaultName)
    }
}
