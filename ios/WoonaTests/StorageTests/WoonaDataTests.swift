import XCTest
import SQLite3
import Network
import CryptoKit
@testable import Woona

final class WoonaDataTests: XCTestCase {
    func testNativeStorageParserConsumesActualIsolatedAPIWireFixture() throws {
        // This file is captured by the server suite from real synthetic HTTP
        // responses, rather than generated from the Swift DTO under test.
        let url = try XCTUnwrap(Bundle(for: WoonaDataTests.self).url(forResource: "storage-api-contract", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(root["contractVersion"] as? Int, 1)
        let response = try XCTUnwrap(root["storageStatus"] as? [String: Any])
        let body = try XCTUnwrap(response["body"] as? [String: Any])
        let value = try JSONDecoder().decode(ServerStorageStatus.self, from: JSONSerialization.data(withJSONObject: body))
        try value.validate(accountID: "qa-storage-wire-contract")
        XCTAssertEqual(value.limits.recordingBytes, 21_474_836_480)
        XCTAssertEqual(value.limits.accountBytes, 107_374_182_400)
        XCTAssertTrue(value.existingUploadsMayResume)
        XCTAssertEqual(value.nextAction, "continue_upload")
        XCTAssertNotEqual(transferNextAction(value.nextAction, ru: false), value.nextAction)
        let server = try XCTUnwrap(body["serverStorage"] as? [String: Any])
        XCTAssertEqual(value.serverStorage.pendingArtifacts, server["pendingArtifacts"] as? Int)
        for key in ["quotaExceeded", "reservationUnavailable"] {
            let response = try XCTUnwrap(root[key] as? [String: Any])
            let body = try XCTUnwrap(response["body"] as? [String: Any])
            let status = try XCTUnwrap(response["httpStatus"] as? Int)
            let headers = try XCTUnwrap(response["headers"] as? [String: String])
            let requestID = try XCTUnwrap(body["requestId"] as? String)
            XCTAssertEqual(headers["x-request-id"], requestID)
            let raw = ServerSyncError.responseError(status: status, data: try JSONSerialization.data(withJSONObject: body)).localizedDescription
            XCTAssertTrue(raw.contains(requestID))
            for field in ["quotaScope", "limitBytes", "reservedBytes", "requestedBytes", "availableBytes", "pendingReservedBytes", "requiredBytes"] where body[field] != nil {
                XCTAssertTrue(raw.contains(field), "Actual server diagnostic \(field) must remain available")
            }
            XCTAssertNotEqual(recordingUploadErrorText(raw, language: .english), raw)
            XCTAssertNotEqual(recordingUploadErrorText(raw, language: .russian), raw)
        }
    }

    private func storageFixture(account: String? = nil, unlimited: Bool = false) throws -> Data {
        let remaining: Any = unlimited ? NSNull() : NSNumber(value: 98_784_247_808 as Int64)
        return try JSONSerialization.data(withJSONObject: [
            "checkedScope": ["accountId": account as Any? ?? NSNull(), "unassignedOnly": account == nil, "includesAllAccounts": false],
            "limits": ["recordingBytes": unlimited ? 0 : 21_474_836_480, "accountBytes": unlimited ? 0 : 107_374_182_400, "freeSpaceReserveBytes": 1_073_741_824],
            "account": ["declaredReservedBytes": 8_589_934_592, "acknowledgedBytes": 1_073_741_824, "remainingQuotaBytes": remaining, "recordings": 6, "artifacts": 18],
            "serverStorage": ["totalBytes": 214_748_364_800, "freeBytes": 21_474_836_480, "freeSpaceReserveBytes": 1_073_741_824, "pendingReservedBytes": 7_516_192_768, "pendingArtifacts": 2, "newReservationAvailableBytes": 12_884_901_888, "scope": "server"],
            "status": "ready", "nextAction": "continue_upload", "existingUploadsMayResume": true,
            "admission": ["blockingReasons": [], "newArtifactUpperBoundBytes": 12_884_901_888]
        ])
    }

    @MainActor
    func testStorageStatusParsesScopedVolumesAndRejectsCrossAccountResponses() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NetworkFaultProtocol.self]
        let bytes = try storageFixture(account: "scope-a", unlimited: true)
        NetworkFaultProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/storage-status")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Woona-Account"), "scope-a")
            return .init(body: bytes)
        }
        defer { NetworkFaultProtocol.handler = nil }
        let client = try WoonaServerClient(configuration: .init(baseURL: "https://network.test", wifiOnly: false, accountID: "scope-a"), token: "fixture", sessionConfiguration: config)
        let value = try await client.storageStatus()
        XCTAssertEqual(value.account.acknowledgedBytes, 1_073_741_824)
        XCTAssertTrue(value.existingUploadsMayResume)
        XCTAssertNil(value.account.remainingQuotaBytes)
        XCTAssertEqual(storageByteText(value.limits.accountBytes, unlimitedWhenZero: true, russian: false), "Unlimited")
        XCTAssertEqual(storageByteText(value.account.remainingQuotaBytes, russian: true), "Без ограничений")
        XCTAssertEqual(storageByteText(0, russian: false), "0.00 GiB")
        XCTAssertEqual(storageByteText(1_073_741_824, russian: true), "1,00 ГиБ")
        XCTAssertThrowsError(try value.validate(accountID: "scope-b"))
        XCTAssertThrowsError(try value.validate(accountID: nil))
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        body["checkedScope"] = ["accountId": "scope-a", "unassignedOnly": false, "includesAllAccounts": true]
        let global = try JSONDecoder().decode(ServerStorageStatus.self, from: JSONSerialization.data(withJSONObject: body))
        XCTAssertThrowsError(try global.validate(accountID: "scope-a"))
        body["checkedScope"] = ["accountId": "scope-a", "unassignedOnly": false, "includesAllAccounts": false]
        var volumes = try XCTUnwrap(body["serverStorage"] as? [String: Any]); volumes["freeBytes"] = -1; body["serverStorage"] = volumes
        let invalid = try JSONDecoder().decode(ServerStorageStatus.self, from: JSONSerialization.data(withJSONObject: body))
        XCTAssertThrowsError(try invalid.validate(accountID: "scope-a"))
    }

    @MainActor
    func testStorageMetadataTimeoutAndCancellationDoNotWaitForConnectivity() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HangingRetirementProtocol.self]
        let client = try WoonaServerClient(configuration: .init(baseURL: "https://retirement.test", wifiOnly: false), token: "fixture", sessionConfiguration: config)
        let start = ProcessInfo.processInfo.systemUptime
        do { _ = try await client.storageStatus(timeout: 0.02); XCTFail("Storage metadata must be bounded") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        let check = Task { try await client.storageStatus() }
        try await Task.sleep(nanoseconds: 20_000_000)
        let cancelledAt = ProcessInfo.processInfo.systemUptime; check.cancel()
        do { _ = try await check.value; XCTFail("Cancelled metadata must not publish a result") }
        catch is CancellationError {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelledAt, 2)
    }

    @MainActor
    func testStorageCheckCancelsStaleConfigurationAndTreats404AsUnsupported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { NetworkFaultProtocol.handler = nil; try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        var hanging = true
        let model = AppViewModel(store: store, uiTesting: true, syncClientFactory: { account in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = hanging ? [HangingRetirementProtocol.self] : [NetworkFaultProtocol.self]
            return try WoonaServerClient(configuration: .init(baseURL: hanging ? "https://retirement.test" : "https://network.test", wifiOnly: false, accountID: account), token: "fixture", sessionConfiguration: config)
        })
        model.serverBaseURL = "https://retirement.test"; model.serverToken = "fixture"
        model.checkServerStorage()
        XCTAssertEqual(model.serverStorageCheck, "checking")
        try await Task.sleep(nanoseconds: 20_000_000)
        model.serverToken = "new-fixture"
        XCTAssertEqual(model.serverStorageCheck, "not_checked"); XCTAssertNil(model.serverStorageStatus)
        hanging = false
        let bytes = try storageFixture()
        NetworkFaultProtocol.handler = { _ in .init(body: bytes) }
        model.serverBaseURL = "https://network.test"; model.checkServerStorage()
        try await awaitStorageCheck(model)
        XCTAssertEqual(model.serverStorageCheck, "checked"); XCTAssertNotNil(model.serverStorageCheckedAt)
        XCTAssertEqual(model.serverStorageStatus?.account.recordings, 6)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(model.serverStorageCheck, "checked", "Old cancelled checks cannot overwrite a new configuration")
        NetworkFaultProtocol.handler = { _ in .init(status: 404, body: Data("{}".utf8)) }
        model.checkServerStorage(); try await awaitStorageCheck(model)
        XCTAssertEqual(model.serverStorageCheck, "unavailable")
        XCTAssertEqual(model.connectionCheck, "not_checked", "An old backend is not evidence that its connection failed")
        XCTAssertNil(model.serverStorageStatus)
    }

    func testStorageErrorsRetainQuotaDetailsAndRequestIDWhileUsingLocalizedReasons() throws {
        for (status, code, action) in [(413, "storage_quota_exceeded", "review_server_storage_limits"), (507, "storage_reservation_unavailable", "retry_after_storage_available"), (429, "integrity_check_busy", "retry_later")] {
            let detail: [String: Any] = ["code": code, "message": "fixture", "requestId": "req-quota-fixture", "nextAction": action, "quotaScope": "account", "limitBytes": 123, "reservedBytes": 100, "requestedBytes": 24]
            for body in [detail, ["detail": detail] as [String: Any]] {
                let data = try JSONSerialization.data(withJSONObject: body)
                let raw = ServerSyncError.responseError(status: status, data: data).localizedDescription
                XCTAssertTrue(raw.contains("req-quota-fixture")); XCTAssertTrue(raw.contains("limitBytes")); XCTAssertTrue(raw.contains(action))
                XCTAssertNotEqual(recordingUploadErrorText(raw, language: .english), raw)
                XCTAssertNotEqual(recordingUploadErrorText(raw, language: .russian), raw)
                XCTAssertNotEqual(transferNextAction(action, ru: false), action)
                XCTAssertNotEqual(transferNextAction(action, ru: true), action)
            }
        }
        XCTAssertEqual(storageAdmissionText("account_quota_reached", russian: false), "Account storage limit reached")
        XCTAssertEqual(recordingUploadErrorText("account_quota_reached", language: .english), "Account storage limit reached")
        XCTAssertEqual(recordingUploadErrorText("account_quota_reached", language: .russian), "Лимит хранения аккаунта исчерпан")
    }

    @MainActor
    func testLargeRestoreFetchesFourDetailsAtATimeAcrossPagesAndAppliesAllMetadata() async throws {
        try await networkSource { root, _ in
            let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
            let profile = try store.saveProfile(self.completeDog())
            let ids = (1...205).map { UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", $0))! }
            let version: [String: Any] = ["id": profile.profileVersionID.uuidString, "schemaVersion": 1,
                "validationState": "complete", "questionnaire": try JSONSerialization.jsonObject(with: WoonaStore.dogQuestionnaireData(profile.questionnaire)),
                "contentSha256": profile.contentSha256, "clientCreatedAtUtc": profile.updatedAtUTC]
            let questionnaire = try JSONSerialization.jsonObject(with: WoonaStore.sessionQuestionnaireData(self.completeSession()))
            func summary(_ id: UUID) -> [String: Any] {
                ["id": id.uuidString, "source": "live", "captureStatus": "completed", "ingestStatus": "uploading",
                 "startedAtUtc": "2026-10-27T13:49:03.123456Z", "sessionLabel": id.uuidString, "videoRequested": false]
            }
            var details: [String: Data] = [:]
            for id in ids {
                let value = summary(id).merging(["dogId": profile.id.uuidString, "profileVersion": version,
                    "timezone": "UTC", "questionnaireSchemaVersion": 1, "questionnaireValidationState": "complete",
                    "sessionQuestionnaire": questionnaire, "sync": ["offsetUs": -12345, "deviceTimer": 9_007_199_254_740_993 as Int64], "artifacts": []]) { _, new in new }
                details["/v1/recordings/" + id.uuidString] = try JSONSerialization.data(withJSONObject: value)
            }
            let first = try JSONSerialization.data(withJSONObject: ["items": ids.prefix(200).map(summary), "nextCursor": ids[199].uuidString])
            let last = try JSONSerialization.data(withJSONObject: ["items": ids.suffix(5).map(summary)])
            RestoreConcurrencyProtocol.reset { request in
                let url = try XCTUnwrap(request.url)
                if url.path == "/v1/deletions" { return .init(body: Data(#"{"entities":[]}"#.utf8)) }
                if url.path.hasSuffix("/recordings") { return .init(body: url.query?.contains("cursor=") == true ? last : first) }
                guard let body = details[url.path] else { throw URLError(.badServerResponse) }
                // Deliberately complete each four-item batch in another order.
                return .init(body: body, delay: url.path.hasSuffix("1") ? 0.04 : 0.015)
            }
            defer { RestoreConcurrencyProtocol.reset(nil) }
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RestoreConcurrencyProtocol.self]
            let client = try WoonaServerClient(configuration: .init(baseURL: "https://restore.test", wifiOnly: false), token: "fixture", sessionConfiguration: config)
            let started = ProcessInfo.processInfo.systemUptime
            let restored = try await client.restoreRecordings(dogIDs: [profile.id], into: store)
            XCTAssertEqual(restored, 205); XCTAssertEqual(try store.localInventory().recordings, 205)
            XCTAssertGreaterThan(RestoreConcurrencyProtocol.maximumActive, 1)
            XCTAssertLessThanOrEqual(RestoreConcurrencyProtocol.maximumActive, 4)
            XCTAssertEqual(RestoreConcurrencyProtocol.finishedCount, 208, "205 detail GETs + two pages + one final deletion reconciliation")
            XCTAssertEqual(Set(try store.recentRecordings(dogID: profile.id, limit: nil).map(\.id)), Set(ids))
            let raw = try XCTUnwrap(store.syncJSON(recordingID: ids[0]))
            XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains("9007199254740993"))
            XCTAssertNil(try store.recording(id: ids[0])?.endedAtUTC)
            XCTAssertTrue(client.restoreWarnings.isEmpty)
            print("Restore benchmark:205details+2pages, max4 concurrent, \(ProcessInfo.processInfo.systemUptime - started)s")
        }
    }

    @MainActor
    func testRestoreListCancellationDoesNotWaitForAHangingMetadataTransport() async throws {
        try await networkSource { root, _ in
            let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
            let profile = try store.saveProfile(self.completeDog())
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HangingRetirementProtocol.self]
            let client = try WoonaServerClient(configuration: .init(baseURL: "https://retirement.test", wifiOnly: false), token: "fixture", sessionConfiguration: config)
            let operation = Task { try await client.restoreProfiles(into: store) }
            try await Task.sleep(nanoseconds: 20_000_000)
            let start = ProcessInfo.processInfo.systemUptime; operation.cancel()
            do { _ = try await operation.value; XCTFail("Restore page cancellation must not await an uncooperative callback") }
            catch is CancellationError {}
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
            XCTAssertEqual(try store.profiles().map(\.id), [profile.id])
        }
    }

    @MainActor
    func testRestoreCancellationCancelsOnlyCurrentBatchAndAppliesNoLateDetails() async throws {
        try await networkSource { root, _ in
            let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
            let profile = try store.saveProfile(self.completeDog())
            let ids = (0..<9).map { _ in UUID() }
            let page = try JSONSerialization.data(withJSONObject: ["items": ids.map { ["id": $0.uuidString] }])
            RestoreConcurrencyProtocol.reset { request in
                if request.url?.path == "/v1/dogs" { return .init(body: page) }
                return .init(body: Data("{}".utf8), delay: 5)
            }
            defer { RestoreConcurrencyProtocol.reset(nil) }
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RestoreConcurrencyProtocol.self]
            let client = try WoonaServerClient(configuration: .init(baseURL: "https://restore.test", wifiOnly: false), token: "fixture", sessionConfiguration: config)
            let operation = Task { try await client.restoreProfiles(into: store) }
            let deadline = Date().addingTimeInterval(5)
            while RestoreConcurrencyProtocol.maximumActive < 4, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertEqual(RestoreConcurrencyProtocol.maximumActive, 4)
            operation.cancel()
            do { _ = try await operation.value; XCTFail("Cancelled restore must stop before applying fetched details") }
            catch is CancellationError {}
            XCTAssertEqual(try store.profiles().map(\.id), [profile.id])
            XCTAssertEqual(try store.localInventory().recordings, 0)
            XCTAssertLessThanOrEqual(RestoreConcurrencyProtocol.maximumActive, 4)
        }
    }

    func testLargeHistoryReadsAreBoundedBulkQueriesWithStableKeysetPages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let profile = try store.saveProfile(completeDog())
        let ids = try seedHistory(root: root, profile: profile, count: 1_205)
        let reader = try WoonaStore(rootDirectory: root, readOnly: true)
        let started = ProcessInfo.processInfo.systemUptime
        let before = reader.queryCountForTesting
        let first = try reader.recordingHistorySnapshot(dogID: profile.id, limit: 100)
        XCTAssertEqual(first.recordings.count, 100); XCTAssertEqual(first.totalCount, 1_205); XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.recordings.map(\.id), Array(ids.reversed().prefix(100)))
        XCTAssertLessThanOrEqual(reader.queryCountForTesting - before, 12, "History must not query sync/artifacts separately for every recording")
        let next = try reader.recordingHistorySnapshot(dogID: profile.id, limit: 100, after: first.cursor)
        XCTAssertEqual(next.recordings.map(\.id), Array(ids.reversed().dropFirst(100).prefix(100)))
        XCTAssertTrue(Set(first.recordings.map(\.id)).isDisjoint(with: next.recordings.map(\.id)))
        XCTAssertTrue(next.hasMore)
        let largeBefore = reader.queryCountForTesting
        let all = try reader.recordingHistorySnapshot(dogID: profile.id, limit: 1_205)
        XCTAssertEqual(all.recordings.count, 1_205); XCTAssertFalse(all.hasMore)
        XCTAssertLessThanOrEqual(reader.queryCountForTesting - largeBefore, 18, "Bulk IN lists must stay bounded while query count scales by chunks, not rows")
        XCTAssertEqual(all.recordings.first?.captureErrorCode, "gatt_error")
        XCTAssertEqual(all.syncErrors[ids.last!], "Synthetic preserved upload failure")
        XCTAssertEqual(all.files[ids.last!]?.local, 1)
        XCTAssertEqual(all.files[ids.last!]?.uploadedBytes, 3)
        XCTAssertEqual(all.recordings.first?.endedAtUTC, nil)
        print("History benchmark: 1,205 records, page100+page100+all bulk reads, \(ProcessInfo.processInfo.systemUptime - started)s")
    }

    func testHistoryNormalizesMixedTimestampPrecisionAndOffsetsWithoutRewritingOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let profile = try store.saveProfile(completeDog())
        let times = ["2026-10-01T10:00:03Z", "2026-10-01T10:00:03.123Z", "2026-10-01T10:00:03.123456Z", "2026-10-01T13:00:03.123+03:00", "2026-10-01T10:00:03.9Z", "not-a-historical-date"]
        let ids = try seedHistory(root: root, profile: profile, count: times.count, timestamps: times)
        let reader = try WoonaStore(rootDirectory: root, readOnly: true)
        var collected: [WoonaRecording] = [], cursor: RecordingHistoryCursor?
        repeat {
            let page = try reader.recordingHistorySnapshot(dogID: profile.id, limit: 2, after: cursor)
            collected += page.recordings; cursor = page.cursor
            if !page.hasMore { break }
        } while cursor != nil
        XCTAssertEqual(collected.map(\.id), [ids[4], ids[3], ids[2], ids[1], ids[0], ids[5]])
        XCTAssertEqual(Set(collected.map(\.id)).count, times.count)
        for (id, time) in zip(ids, times) { XCTAssertEqual(try store.recording(id: id)?.startedAtUTC, time) }
    }

    @MainActor
    func testHistoryPaginationRunsOffMainActorAndRejectsLateResultsForAnotherAnimal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let profile = try store.saveProfile(completeDog())
        let originalIDs = try seedHistory(root: root, profile: profile, count: 205)
        var other = completeDog(); other.numberOrName = "Another animal"
        let second = try store.saveProfile(other)
        let model = AppViewModel(store: store, uiTesting: true)
        model.selectDogProfile(profile)
        try await awaitHistoryForTesting(model)
        XCTAssertEqual(model.recentRecordings.count, 10)
        model.showAllRecordings(); try await awaitHistoryForTesting(model)
        XCTAssertEqual(model.recentRecordings.count, 100); XCTAssertEqual(model.historyTotalCount, 205)
        let prefix = model.recentRecordings.map(\.id)
        let inserted = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
        let lateOlder = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("woona.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        try fixtureSQL(database, "UPDATE recordings SET started_at_utc='1970-01-01T00:00:00Z' WHERE id=\(fixtureSQLText(lateOlder.id.uuidString))")
        model.showMoreRecordings(); try await awaitHistoryForTesting(model)
        XCTAssertEqual(model.recentRecordings.count, 200)
        XCTAssertEqual(model.historyTotalCount, 205, "Unseen new top items must not inflate the current cursor snapshot")
        XCTAssertEqual(Array(model.recentRecordings.prefix(100)).map(\.id), prefix)
        XCTAssertFalse(model.recentRecordings.contains { $0.id == inserted.id || $0.id == lateOlder.id }, "Neither new top nor new older rows belong to the original page membership")
        XCTAssertEqual(model.nextHistoryPageCount, 5)
        let removed = fixtureSQLText(originalIDs[0].uuidString)
        try fixtureSQL(database, "DELETE FROM artifacts WHERE recording_id=\(removed); DELETE FROM recording_sync WHERE recording_id=\(removed); DELETE FROM server_sync_state WHERE recording_id=\(removed); DELETE FROM recordings WHERE id=\(removed)")
        model.showMoreRecordings(); try await awaitHistoryForTesting(model)
        XCTAssertEqual(model.recentRecordings.count, 204)
        XCTAssertEqual(model.historyTotalCount, 205, "A deletion keeps the as-of count until explicit Refresh")
        XCTAssertTrue(model.historyChangedDuringPagination)
        XCTAssertFalse(model.hasMoreRecordings)
        model.refreshRecordingHistory(); try await awaitHistoryForTesting(model)
        XCTAssertEqual(model.recentRecordings.count, 100)
        XCTAssertEqual(model.historyTotalCount, 206)
        XCTAssertFalse(model.historyChangedDuringPagination)
        XCTAssertTrue(model.recentRecordings.contains { $0.id == inserted.id })
        let entered = expectation(description: "History IO worker entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        model.onHistoryReadStartForTesting = { XCTAssertFalse(Thread.isMainThread); entered.fulfill(); release.wait() }
        model.refreshRecordingHistory()
        await fulfillment(of: [entered], timeout: 5)
        model.selectedTab = .settings
        XCTAssertEqual(model.selectedTab, .settings)
        XCTAssertTrue(model.isHistoryLoading)
        model.onHistoryReadStartForTesting = nil
        model.selectDogProfile(second)
        release.signal()
        try await awaitHistoryForTesting(model)
        XCTAssertEqual(model.selectedDogProfile?.id, second.id)
        XCTAssertTrue(model.recentRecordings.isEmpty, "The old animal's late read must not repopulate the new animal")
        XCTAssertEqual(model.historyTotalCount, 0)
    }

    @MainActor
    func testReusedSQLiteRowIDCannotMakeTheFrozenHistoryCounterImpossible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let profile = try store.saveProfile(completeDog())
        let ids = try seedHistory(root: root, profile: profile, count: 105)
        let model = AppViewModel(store: store, uiTesting: true)
        try await awaitHistoryForTesting(model)
        model.showAllRecordings(); try await awaitHistoryForTesting(model)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("woona.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let removed = fixtureSQLText(ids.last!.uuidString)
        try fixtureSQL(database, "DELETE FROM artifacts WHERE recording_id=\(removed); DELETE FROM recording_sync WHERE recording_id=\(removed); DELETE FROM server_sync_state WHERE recording_id=\(removed); DELETE FROM recordings WHERE id=\(removed)")
        let inserted = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
        try fixtureSQL(database, "UPDATE recordings SET started_at_utc='1970-01-01T00:00:00Z' WHERE id=\(fixtureSQLText(inserted.id.uuidString))")
        model.showMoreRecordings(); try await awaitHistoryForTesting(model)
        XCTAssertEqual(model.recentRecordings.count, 105)
        XCTAssertEqual(model.historyTotalCount, 105)
        XCTAssertFalse(model.hasMoreRecordings)
        XCTAssertFalse(model.recentRecordings.contains { $0.id == inserted.id }, "A reused ROWID must not add a 106th row to a 105-item snapshot")
    }

    @MainActor
    func testGlobalQueueRemainsVisibleWhenSelectedAccountHasNoAnimal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let hidden = try store.saveProfile(completeDog(), accountID: "another-account")
        _ = try seedHistory(root: root, profile: hidden, count: 1)
        let model = AppViewModel(store: store, uiTesting: true)
        try await awaitHistoryForTesting(model)
        XCTAssertNil(model.selectedDogProfile)
        XCTAssertTrue(model.recentRecordings.isEmpty)
        XCTAssertEqual(model.uploadFailed, 1, "Settings shows all-account queue, including hidden animals")
        XCTAssertEqual(model.uploadLastError, "Synthetic preserved upload failure")
    }

    @MainActor
    func testHistoryReadFailureDoesNotCreateAnEmptyDatabaseAndCanBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let profile = try store.saveProfile(completeDog())
        _ = try seedHistory(root: root, profile: profile, count: 12)
        let model = AppViewModel(store: store, uiTesting: true)
        try await awaitHistoryForTesting(model)
        let original = model.recentRecordings.map(\.id)
        let database = root.appendingPathComponent("woona.sqlite")
        let originalHash = try WoonaStore.sha256File(database)
        let missingRoot = root.appendingPathComponent("unavailable-store")
        // Never rename a live SQLite vnode: Apple's VFS invalidates its open
        // descriptor, which can corrupt test isolation. Perform a real failed
        // read-only open on an absent synthetic path inside the history worker.
        model.onHistoryReadStartForTesting = { _ = try WoonaStore(rootDirectory: missingRoot, readOnly: true) }
        model.refreshRecordingHistory(); try await awaitHistoryForTesting(model, allowFailure: true)
        XCTAssertNotNil(model.historyLoadError)
        XCTAssertEqual(model.recentRecordings.map(\.id), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot.appendingPathComponent("woona.sqlite").path), "A read failure must not create a new empty store")
        XCTAssertEqual(try WoonaStore.sha256File(database), originalHash)
        model.onHistoryReadStartForTesting = nil
        model.retryLoadingHistory(); try await awaitHistoryForTesting(model)
        XCTAssertNil(model.historyLoadError); XCTAssertEqual(model.recentRecordings.map(\.id), original)
    }

    private func seedHistory(root: URL, profile: DogProfile, count: Int, timestamps: [String]? = nil) throws -> [UUID] {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("woona.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let json = String(decoding: try WoonaStore.sessionQuestionnaireData(completeSession()), as: UTF8.self)
        try fixtureSQL(database, "BEGIN")
        let clockJSON = #"{"captureErrorCode":"gatt_error"}"#
        var ids: [UUID] = []
        for index in 1...count {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
            ids.append(id)
            let time = timestamps?[index - 1] ?? "2026-10-01T10:00:00.123456Z"
            let directory = "recordings/\(profile.id.uuidString)/2026-10-01/\(id.uuidString)"
            try fixtureSQL(database, "INSERT INTO recordings VALUES(\(fixtureSQLText(id.uuidString)),\(fixtureSQLText(profile.id.uuidString)),\(fixtureSQLText(profile.profileVersionID.uuidString)),'live','completed','Synthetic history',0,\(fixtureSQLText(time)),NULL,'Europe/Moscow',\(fixtureSQLText(json)),\(fixtureSQLText(directory)),'permanent_error','fixture',1,0);")
            try fixtureSQL(database, "INSERT INTO recording_sync VALUES(\(fixtureSQLText(id.uuidString)),\(fixtureSQLText(clockJSON)),\(fixtureSQLText(time)));")
            try fixtureSQL(database, "INSERT INTO server_sync_state VALUES(\(fixtureSQLText(id.uuidString)),'permanent_error',1,NULL,'fixture_error','Synthetic preserved upload failure',NULL,\(fixtureSQLText(time)));")
            let path = directory + "/packets.bin"
            if index == count {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
                try Data("original".utf8).write(to: root.appendingPathComponent(path))
            }
            try fixtureSQL(database, "INSERT INTO artifacts VALUES(\(fixtureSQLText(UUID().uuidString)),\(fixtureSQLText(id.uuidString)),'packet','packets.bin',\(fixtureSQLText(path)),'application/octet-stream',8,'fixture-hash','uploading',3,\(fixtureSQLText(time)),NULL);")
        }
        try fixtureSQL(database, "COMMIT")
        return ids
    }

    func testEveryDocumentedHistoricalSchemaMigratesWithoutChangingOriginalDataOrFiles() throws {
        for schema in HistoricalIOSSchema.allCases {
            try XCTContext.runActivity(named: "Historical iOS \(schema), version \(schema.version)") { _ in
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                var database: OpaquePointer?
                XCTAssertEqual(sqlite3_open(root.appendingPathComponent("woona.sqlite").path, &database), SQLITE_OK)
                defer { sqlite3_close(database) }
                try fixtureSQL(database, schema.sql)
                let dogID = UUID(), oldVersion = UUID(), currentVersion = UUID()
                let recordID = UUID(), activeID = UUID(), packetID = UUID(), syncID = UUID(), referenceID = UUID()
                let time = "2026-10-01T10:00:00.123456Z"
                var older = completeDog(); older.numberOrName = "Historical name"
                var current = older; current.numberOrName = "Current name"
                let oldJSON = String(decoding: try WoonaStore.dogQuestionnaireData(older), as: UTF8.self)
                let currentJSON = String(decoding: try WoonaStore.dogQuestionnaireData(current), as: UTF8.self)
                let sessionJSON = String(decoding: try WoonaStore.sessionQuestionnaireData(completeSession()), as: UTF8.self)
                let directory = "recordings/\(dogID.uuidString)/2026-10-01/\(recordID.uuidString)"
                let packet = Data("Original historical packet bytes".utf8)
                let clock = Data(#"{"monotonicClock":"ios.CMClock.hostTime","sessionZeroMonotonicNs":9007199254740993,"videoOffsetFromSensorNs":-7001,"captureErrorCode":"gatt_error","captureErrorMessage":"GATT status 8"}"#.utf8)
                let folder = root.appendingPathComponent(directory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try packet.write(to: folder.appendingPathComponent("packets.bin"))
                try clock.write(to: folder.appendingPathComponent("sync.json"))
                let note = Data("Unregistered original note".utf8)
                try note.write(to: folder.appendingPathComponent("operator-note.txt"))
                try fixtureSQL(database, "INSERT INTO dogs VALUES(\(fixtureSQLText(dogID.uuidString)),\(fixtureSQLText(currentVersion.uuidString)),'Current name',7,\(fixtureSQLText(time)),\(fixtureSQLText(time)),NULL\(schema.hasAccount ? ", 'fixture-clinic'" : ""));")
                for (id, json, superseded) in [(oldVersion, oldJSON, fixtureSQLText(time)), (currentVersion, currentJSON, "NULL")] {
                    try fixtureSQL(database, "INSERT INTO dog_profile_versions VALUES(\(fixtureSQLText(id.uuidString)),\(fixtureSQLText(dogID.uuidString)),1,'complete',\(fixtureSQLText(json)),\(fixtureSQLText(WoonaStore.sha256(Data(json.utf8)))),\(fixtureSQLText(time)),\(superseded));")
                }
                for (id, status, end, state) in [(recordID, "completed", fixtureSQLText(time), "synced"), (activeID, "recording", "NULL", "pending")] {
                    let suffix = (schema.hasAppVersion ? ",'historical-build'" : "") + (schema.hasAccount ? ",4,1" : "")
                    let path = id == recordID ? directory : directory + "-active"
                    try fixtureSQL(database, "INSERT INTO recordings VALUES(\(fixtureSQLText(id.uuidString)),\(fixtureSQLText(dogID.uuidString)),\(fixtureSQLText(oldVersion.uuidString)),'live',\(fixtureSQLText(status)),'Historical session',0,\(fixtureSQLText(time)),\(end),'Europe/Moscow',\(fixtureSQLText(sessionJSON)),\(fixtureSQLText(path)),\(fixtureSQLText(state))\(suffix));")
                }
                try fixtureSQL(database, "INSERT INTO recording_sync VALUES(\(fixtureSQLText(recordID.uuidString)),\(fixtureSQLText(String(decoding: clock, as: UTF8.self))),\(fixtureSQLText(time)));")
                for (id, kind, name, bytes) in [(packetID, "packet", "packets.bin", packet), (syncID, "sync", "sync.json", clock)] {
                    try fixtureSQL(database, "INSERT INTO artifacts VALUES(\(fixtureSQLText(id.uuidString)),\(fixtureSQLText(recordID.uuidString)),\(fixtureSQLText(kind)),\(fixtureSQLText(name)),\(fixtureSQLText(directory + "/" + name)),'application/octet-stream',\(bytes.count),\(fixtureSQLText(WoonaStore.sha256(bytes))),'available',\(bytes.count),\(fixtureSQLText(time))\(schema.hasReference ? ",NULL" : ""));")
                }
                var reference = ReferenceMetadata()
                reference.source = "Synthetic reference"; reference.startedAtUtc = time
                reference.endedAtUtc = time; reference.offsetFromRecordingMs = -7.001; reference.notes = "Original reference metadata"
                if schema.hasReference {
                    let bytes = Data("time,value\n0,1\n".utf8)
                    try bytes.write(to: folder.appendingPathComponent("ecg.csv"))
                    let json = String(decoding: try JSONEncoder().encode(reference), as: UTF8.self)
                    try fixtureSQL(database, "INSERT INTO artifacts VALUES(\(fixtureSQLText(referenceID.uuidString)),\(fixtureSQLText(recordID.uuidString)),'ecg','ecg.csv',\(fixtureSQLText(directory + "/ecg.csv")),'text/csv',\(bytes.count),\(fixtureSQLText(WoonaStore.sha256(bytes))),'available',\(bytes.count),\(fixtureSQLText(time)),\(fixtureSQLText(json)));")
                }
                try fixtureSQL(database, "INSERT INTO server_sync_state VALUES(\(fixtureSQLText(recordID.uuidString)),'synced',3,NULL,NULL,NULL,'immutable-receipt',\(fixtureSQLText(time)));")
                if schema.hasProfileQueue {
                    try fixtureSQL(database, "INSERT INTO profile_sync_state VALUES(\(fixtureSQLText(currentVersion.uuidString)),'synced',NULL,\(fixtureSQLText(time)));")
                    try fixtureSQL(database, "INSERT INTO profile_sync_state VALUES(\(fixtureSQLText(oldVersion.uuidString)),'permanent_error','original failure',\(fixtureSQLText(time)));")
                }
                if schema.hasRetirementQueue {
                    try fixtureSQL(database, "INSERT INTO local_deletion_outbox VALUES('existing-cleanup','recordings/already-retired/source.bin','file',\(fixtureSQLText(time)),'original cleanup error');")
                    try fixtureSQL(database, "INSERT INTO deferred_retirements VALUES('recording','unmatched-authoritative-marker',\(fixtureSQLText(time)));")
                }
                for _ in 0..<2 {
                    let store = try WoonaStore(rootDirectory: root)
                    XCTAssertEqual(try fixtureScalar(database, "PRAGMA user_version"), "8")
                    XCTAssertEqual(try fixtureScalar(database, "PRAGMA integrity_check"), "ok")
                    XCTAssertEqual(try fixtureScalar(database, "SELECT COUNT(*) FROM dog_profile_versions"), "2")
                    XCTAssertEqual(try store.localInventory().recordings, 2)
                    let profile = try XCTUnwrap(store.profiles().first)
                    XCTAssertEqual(profile.id, dogID); XCTAssertEqual(profile.profileVersionID, currentVersion)
                    XCTAssertEqual(profile.questionnaire, current); XCTAssertEqual(profile.revision, 7)
                    XCTAssertEqual(profile.accountID, schema.hasAccount ? "fixture-clinic" : nil)
                    XCTAssertEqual(try store.profile(dogID: dogID, versionID: oldVersion)?.questionnaire, older)
                    let saved = try XCTUnwrap(store.recording(id: recordID))
                    XCTAssertEqual(saved.profileVersionID, oldVersion); XCTAssertEqual(saved.startedAtUTC, time)
                    XCTAssertEqual(saved.endedAtUTC, time); XCTAssertEqual(saved.relativeDirectory, directory)
                    XCTAssertEqual(saved.serverSyncState, "synced"); XCTAssertEqual(saved.captureErrorCode, "gatt_error")
                    XCTAssertEqual(saved.questionnaireRevision, schema.hasAccount ? 4 : 1)
                    XCTAssertEqual(saved.questionnaireDirty, schema.hasAccount)
                    XCTAssertEqual(saved.appVersion, schema.hasAppVersion ? "historical-build" : nil)
                    let active = try XCTUnwrap(store.recording(id: activeID))
                    XCTAssertEqual(active.status, "recording"); XCTAssertNil(active.endedAtUTC)
                    XCTAssertEqual(try store.syncJSON(recordingID: recordID), clock)
                    XCTAssertEqual(try fixtureScalar(database, "SELECT server_receipt_sha256 FROM server_sync_state"), "immutable-receipt")
                    XCTAssertEqual(try store.profileSyncState(versionID: currentVersion), schema.hasProfileQueue ? "synced" : "pending")
                    XCTAssertEqual(try store.profileSyncState(versionID: oldVersion), schema.hasProfileQueue ? "permanent_error" : "pending")
                    if schema.hasProfileQueue { XCTAssertEqual(try fixtureScalar(database, "SELECT last_error FROM profile_sync_state WHERE profile_version_id=\(fixtureSQLText(oldVersion.uuidString))"), "original failure") }
                    let artifacts = try store.artifacts(recordingID: recordID)
                    XCTAssertEqual(Set(artifacts.map(\.id)), Set([packetID, syncID] + (schema.hasReference ? [referenceID] : [])))
                    if schema.hasReference { XCTAssertEqual(artifacts.first { $0.id == referenceID }?.referenceMetadata, reference) }
                    XCTAssertTrue(artifacts.allSatisfy { $0.uploadState == "available" && $0.uploadedBytes == $0.sizeBytes })
                    XCTAssertEqual(try WoonaStore.sha256File(folder.appendingPathComponent("packets.bin")), WoonaStore.sha256(packet))
                    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("sync.json")), clock)
                    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("operator-note.txt")), note)
                    XCTAssertEqual(try store.retirementCleanupStatus().pendingCount, schema.hasRetirementQueue ? 1 : 0)
                    XCTAssertEqual(try fixtureScalar(database, "SELECT COUNT(*) FROM deferred_retirements"), schema.hasRetirementQueue ? "1" : "0")
                }
            }
        }
    }

    func testFailedHistoricalUpgradeRollsBackCreatedTablesAndPreservesFilesAndSchemaVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("Preserved original before failed migration".utf8)
        let source = root.appendingPathComponent("original.bin"); try original.write(to: source)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("woona.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        try fixtureSQL(database, HistoricalIOSSchema.initial5.sql)
        // Fault injection: a view cannot receive ALTER TABLE; old metadata remains available.
        try fixtureSQL(database, "ALTER TABLE artifacts RENAME TO original_artifacts; CREATE VIEW artifacts AS SELECT * FROM original_artifacts;")
        XCTAssertThrowsError(try WoonaStore(rootDirectory: root))
        XCTAssertEqual(try fixtureScalar(database, "PRAGMA user_version"), "5")
        XCTAssertEqual(try fixtureScalar(database, "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('profile_sync_state','local_deletion_outbox','deferred_retirements')"), "0")
        XCTAssertEqual(try fixtureScalar(database, "SELECT type FROM sqlite_master WHERE name='artifacts'"), "view")
        XCTAssertEqual(try fixtureScalar(database, "PRAGMA integrity_check"), "ok")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testServerBaseURLAllowsHttpsAndOnlyExactLocalHttpHosts() throws {
        for input in ["https://example.test", "HTTPS://Example.test:8443/api/root", "https://[2001:db8::1]:8443/api%20root",
                      "http://10.0.2.2:8080", "http://localhost:18088", "http://127.0.0.1:18088", "http://[::1]:18088"] {
            let url = try ServerConfiguration.validatedBaseURL(" \(input)///\n")
            XCTAssertEqual(url.absoluteString.lowercased(), input.lowercased())
        }
    }

    @MainActor
    func testServerBaseURLRejectsUnsafeConfigurationBeforeNetworking() {
        for input in ["", "https://", "https:///v1", "https:example.test", "example.test", "ftp://example.test",
                      "https://user:secret@example.test", "https://@example.test", "https://example.test?x=1", "https://example.test?",
                      "https://example.test#fragment", "https://example.test#", "https://example.test:", "https://example.test:0",
                      "https://example.test:65536", "https://example.test:abc", "https://bad host", "https://bad_host",
                      "https://999.999.999.999", "https://[bad::g]", "https://example.test/has space", "https://example.test/\\escape",
                      "http://example.test", "http://10.0.2.2.evil", "http://10.0.2.20", "http://127.0.0.2", "http://localhost.evil"] {
            XCTAssertThrowsError(try WoonaServerClient(configuration: .init(baseURL: input, wifiOnly: false), token: "fixture"), input) { error in
                guard case ServerSyncError.invalidURL = error else { return XCTFail("Expected local configuration error") }
                XCTAssertTrue(error.localizedDescription.contains("HTTPS"))
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
    }

    @MainActor
    func testConfiguredServerBasePrefixIsUsedByActualConnectionRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkFaultProtocol.self]
        var urls: [URL] = []
        NetworkFaultProtocol.handler = { request in
            urls.append(try XCTUnwrap(request.url))
            return .init(body: Data("{}".utf8))
        }
        defer { NetworkFaultProtocol.handler = nil }
        let client = try WoonaServerClient(configuration: .init(baseURL: "https://network.test/api/root///", wifiOnly: false),
                                          token: "fixture", sessionConfiguration: configuration)
        try await client.checkConnection()
        XCTAssertEqual(urls.map(\.path), ["/api/root/health/ready", "/api/root/v1/dogs"])
        XCTAssertEqual(urls.last?.query, "limit=1")
    }

    @MainActor
    private func networkSource(_ test: (URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.bin")
        try Data("abcdef".utf8).write(to: source)
        defer { NetworkFaultProtocol.handler = nil; try? FileManager.default.removeItem(at: root) }
        try await test(root, source)
    }

    @MainActor
    private func networkClient(download: WoonaServerClient.DownloadTransport? = nil) throws -> WoonaServerClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkFaultProtocol.self]
        return try WoonaServerClient(configuration: .init(baseURL: "https://network.test", wifiOnly: false), token: "fixture",
                                     sessionConfiguration: configuration, downloadTransport: download)
    }

    @MainActor
    func testStaleRetirementResultCannotDeleteLocalFilesAndDisconnectedClientsCannotSendAgain() async throws {
        try await networkSource { root, _ in
            let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
            let profile = try store.saveProfile(completeDog())
            let local = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
            try store.finalize(recording: local, status: "completed", files: [], syncJSON: Data("{}".utf8))
            let marker: [String: Any] = ["kind": "recording", "id_sha256": WoonaStore.sha256(Data(local.id.uuidString.lowercased().utf8))]
            var requests = 0
            NetworkFaultProtocol.handler = { _ in
                requests += 1
                return .init(body: try JSONSerialization.data(withJSONObject: ["entities": [marker]]))
            }
            let oldClient = try networkClient()
            do { _ = try await oldClient.reconcileDeletions(into: store, acceptResult: { false }); XCTFail("Stale settings must not apply retirement") }
            catch is CancellationError {}
            XCTAssertNotNil(try store.recording(id: local.id))
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(for: local).path))
            XCTAssertEqual(try store.retirementCleanupStatus().pendingCount, 0)
            XCTAssertEqual(requests, 1)
            WoonaServerClient.cancelAllTransfers()
            do { try await oldClient.checkConnection(); XCTFail("Disconnected clients cannot retain usable credentials") }
            catch is CancellationError {}
            XCTAssertEqual(requests, 1)
            let freshClient = try networkClient()
            try await freshClient.checkConnection()
            XCTAssertEqual(requests, 3, "A newly connected client can check both readiness and access")
        }
    }

    @MainActor
    func testRetirementCheckTimeoutCancelsTheHangingRequestWithoutDeletingLocalData() async throws {
        try await networkSource { root, _ in
            let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
            _ = try store.saveProfile(completeDog())
            let previousOwner = HangingRetirementProtocol.reset()
            let previousConfig = URLSessionConfiguration.ephemeral
            previousConfig.protocolClasses = [HangingRetirementProtocol.self]
            let previousClient = try WoonaServerClient(configuration: .init(baseURL: "https://retirement.test/" + previousOwner, wifiOnly: false), token: "fixture", sessionConfiguration: previousConfig)
            let previous = Task { try await previousClient.deletions() }
            defer { previous.cancel() }
            try await Task.sleep(nanoseconds: 20_000_000)
            let owner = HangingRetirementProtocol.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HangingRetirementProtocol.self]
            let client = try WoonaServerClient(configuration: .init(baseURL: "https://retirement.test/" + owner, wifiOnly: false), token: "fixture", sessionConfiguration: configuration)
            let started = ProcessInfo.processInfo.systemUptime
            do { _ = try await client.reconcileDeletions(into: store, timeout: 0.02); XCTFail("A hanging maintenance request must be bounded") }
            catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2,
                              "Timeout returns without waiting for the uncooperative URLProtocol")
            previous.cancel()
            do { _ = try await previous.value; XCTFail("Previous request must also cancel") }
            catch is CancellationError {}
            let deadline = Date().addingTimeInterval(5)
            while HangingRetirementProtocol.stoppedCount == 0, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertEqual(HangingRetirementProtocol.stoppedCount, 1)
            XCTAssertEqual(try store.profiles().count, 1)
            XCTAssertEqual(try store.retirementCleanupStatus().pendingCount, 0)
            XCTAssertEqual(try store.retirementCleanupStatus().deferredCount, 0)
        }
    }

    @MainActor
    func testRetirementCheckCancellationDoesNotWaitForTheHangingRequest() async throws {
        try await networkSource { root, _ in
            let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
            _ = try store.saveProfile(completeDog())
            let owner = HangingRetirementProtocol.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HangingRetirementProtocol.self]
            let client = try WoonaServerClient(configuration: .init(baseURL: "https://retirement.test/" + owner, wifiOnly: false), token: "fixture", sessionConfiguration: configuration)
            let check = Task { try await client.reconcileDeletions(into: store) }
            try await Task.sleep(nanoseconds: 20_000_000)
            let cancelledAt = ProcessInfo.processInfo.systemUptime
            check.cancel()
            do { _ = try await check.value; XCTFail("Cancellation must return before a network callback") }
            catch is CancellationError {}
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelledAt, 2)
            XCTAssertEqual(try store.profiles().count, 1)
            XCTAssertEqual(try store.retirementCleanupStatus().pendingCount, 0)
        }
    }

    func testProfileVersionAcceptanceAndMigrationNeverInferAcknowledgmentFromDogRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var store: WoonaStore? = try WoonaStore(rootDirectory: root)
        defer { store = nil; try? FileManager.default.removeItem(at: root) }
        let first = try store!.saveProfile(completeDog(), accountID: "scope-a")
        try store!.markProfileAccepted(dogID: first.id, versionID: first.profileVersionID)
        try store!.setServerRevision(dogID: first.id, revision: 7)
        let recording = try store!.createRecording(profile: first, source: "live", questionnaire: completeSession())
        var changed = first.questionnaire; changed.numberOrName = "Revised name"
        let second = try store!.saveProfile(changed, replacing: first)
        XCTAssertEqual(second.revision, 7)
        XCTAssertNotEqual(second.profileVersionID, first.profileVersionID)
        XCTAssertEqual(try store!.pendingProfiles().map(\.profileVersionID), [second.profileVersionID])
        XCTAssertEqual(try store!.profileSyncState(versionID: first.profileVersionID), "synced")
        XCTAssertEqual(try store!.recording(id: recording.id)?.profileVersionID, first.profileVersionID)
        // A receipt for the frozen old version cannot confirm the new current UUID.
        try store!.markProfileAccepted(dogID: first.id, versionID: first.profileVersionID)
        XCTAssertEqual(try store!.profileSyncState(versionID: second.profileVersionID), "pending")
        _ = try store!.upsertRemoteProfile(dogID: first.id, profileVersionID: first.profileVersionID,
            revision: 8, questionnaire: first.questionnaire, contentSha256: first.contentSha256,
            updatedAtUTC: first.updatedAtUTC, accountID: "scope-a")
        XCTAssertEqual(try store!.profiles().first?.profileVersionID, second.profileVersionID)
        XCTAssertEqual(try store!.profileSyncState(versionID: second.profileVersionID), "pending")
        store = nil
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("woona.sqlite").path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "DROP TABLE profile_sync_state; PRAGMA user_version=6", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        store = try WoonaStore(rootDirectory: root)
        let migrated = try XCTUnwrap(store!.profiles().first)
        XCTAssertEqual(migrated.profileVersionID, second.profileVersionID)
        XCTAssertEqual(migrated.revision, 8)
        XCTAssertEqual(migrated.contentSha256, second.contentSha256)
        XCTAssertEqual(try store!.pendingProfiles().map(\.profileVersionID), [second.profileVersionID])
        XCTAssertEqual(try store!.recording(id: recording.id)?.profileVersionID, first.profileVersionID)
    }

    @MainActor
    func testProfileOnlyQueueIsAwaitedScopedAndStopsAutomaticIdentityConflictRetry() async throws {
        try await networkSource { root, _ in
            let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
            let profile = try store.saveProfile(completeDog(), accountID: "scope-a")
            var puts = 0
            var reject = true
            NetworkFaultProtocol.handler = { request in
                if request.url!.path == "/v1/deletions" {
                    // Global maintenance uses the selected workspace; profile
                    // upload also reconciles through its own scoped client.
                    let account = request.value(forHTTPHeaderField: "X-Woona-Account")
                    XCTAssertTrue(account == nil || account == "scope-a")
                    return .init(body: Data(#"{"entities":[]}"#.utf8))
                }
                if request.httpMethod == "PUT" {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Woona-Account"), "scope-a")
                    puts += 1
                    XCTAssertTrue(request.url!.path.hasSuffix(profile.profileVersionID.uuidString))
                    if reject { return .init(status: 409, body: Data(#"{"detail":{"code":"animal_id_already_exists","message":"Synthetic identity conflict"}}"#.utf8)) }
                    return .init(body: Data(#"{"dogRevision":8}"#.utf8))
                }
                throw URLError(.badServerResponse)
            }
            let model = AppViewModel(store: store, uiTesting: true, syncClientFactory: { account in
                XCTAssertTrue(account == nil || account == "scope-a") // Global check or profile-origin upload.
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NetworkFaultProtocol.self]
                return try WoonaServerClient(configuration: .init(baseURL: "https://network.test", wifiOnly: false, accountID: account), token: "fixture", sessionConfiguration: config)
            })
            model.updateTransferNetworkPath(available: true, unmetered: true)
            // Real worker IO can outlive an arbitrary number of MainActor yields,
            // especially with TSan. Finish startup reads and the token-empty
            // scheduled network pass before invoking this lower-level API.
            try await awaitHistoryForTesting(model)
            let readyDeadline = Date().addingTimeInterval(10)
            while !model.canChangeAccount, Date() < readyDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(model.canChangeAccount, model.serverMutationBlockedReason ?? "Startup did not become ready")
            XCTAssertTrue(model.transferNetworkAllowsWork)
            model.serverToken = "fixture"
            let rejected = await model.resumePendingSync()
            XCTAssertFalse(rejected)
            XCTAssertEqual(puts, 1, model.diagnosticMessages.joined(separator: "\n"))
            XCTAssertEqual(try store.profileSyncState(versionID: profile.profileVersionID), "permanent_error")
            XCTAssertEqual(model.profileUploadFailed, 1)
            XCTAssertFalse(model.uploadQueueExplanation.contains("queue is empty"))
            let automatic = await model.resumePendingSync()
            XCTAssertTrue(automatic) // No eligible retry remains; this does not mark it uploaded.
            XCTAssertEqual(puts, 1)
            XCTAssertEqual(try store.profileSyncOverview().failed, 1)
            try store.resetFailedSync() // Same persistent reset used by the explicit Retry button.
            reject = false
            let retried = await model.resumePendingSync()
            XCTAssertTrue(retried)
            XCTAssertEqual(puts, 2)
            XCTAssertEqual(try store.profileSyncState(versionID: profile.profileVersionID), "synced")
            XCTAssertEqual(try store.profiles().first?.revision, 8)
            XCTAssertEqual(model.profileUploadPending, 0)
            XCTAssertEqual(model.profileUploadFailed, 0)
            XCTAssertEqual(try store.localInventory().recordings, 0)
        }
    }

    @MainActor
    func testBackgroundFirstPathOwnsAndAwaitsAProfileOnlyQueueWithoutSpawningAutosync() async throws {
        try await networkSource { root, _ in
            let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
            let profile = try store.saveProfile(completeDog())
            var puts = 0
            NetworkFaultProtocol.handler = { request in
                if request.url!.path == "/v1/deletions" { return .init(body: Data(#"{"entities":[]}"#.utf8)) }
                if request.httpMethod == "PUT" { puts += 1; return .init(body: Data(#"{"dogRevision":3}"#.utf8)) }
                throw URLError(.badServerResponse)
            }
            let model = AppViewModel(store: store, uiTesting: true, syncClientFactory: { _ in try self.networkClient() })
            model.serverToken = "fixture"
            let operation = Task { await model.performBackgroundSync(networkTimeout: 1) }
            for _ in 0..<100 {
                if model.isBackgroundSyncRunning { break }
                await Task.yield()
            }
            XCTAssertTrue(model.isBackgroundSyncRunning)
            XCTAssertFalse(model.canChangeAccount)
            XCTAssertEqual(puts, 0)
            model.updateTransferNetworkPath(available: true, unmetered: true)
            let completed = await operation.value
            XCTAssertTrue(completed)
            XCTAssertFalse(model.isBackgroundSyncRunning)
            XCTAssertEqual(puts, 1)
            XCTAssertEqual(try store.profileSyncState(versionID: profile.profileVersionID), "synced")
            XCTAssertEqual(model.profileUploadPending, 0)
            XCTAssertEqual(try store.localInventory().recordings, 0)
        }
    }

    @MainActor
    func testProfileAcknowledgmentCannotAcceptAnotherUUIDAndTransientFailurePersistsForRetry() async throws {
        try await networkSource { root, _ in
            let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
            let profile = try store.saveProfile(completeDog())
            var stage = 0
            NetworkFaultProtocol.handler = { request in
                if request.url!.path == "/v1/deletions" { return .init(body: Data(#"{"entities":[]}"#.utf8)) }
                if stage == 0 { throw URLError(.timedOut) }
                let questionnaire = try JSONSerialization.jsonObject(with: WoonaStore.dogQuestionnaireData(profile.questionnaire))
                let receipt: [String: Any] = ["dogRevision": 9, "profileVersion": [
                    "id": UUID().uuidString, "schemaVersion": profile.questionnaire.schemaVersion,
                    "validationState": "complete", "questionnaire": questionnaire, "contentSha256": profile.contentSha256,
                    "clientCreatedAtUtc": profile.updatedAtUTC, "supersededAtUtc": NSNull()]]
                return .init(body: try JSONSerialization.data(withJSONObject: receipt))
            }
            do { _ = try await networkClient().upload(profile: profile, store: store); XCTFail("timeout must fail") }
            catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
            XCTAssertEqual(try store.profileSyncState(versionID: profile.profileVersionID), "retryable_error")
            XCTAssertEqual(try store.pendingProfiles().count, 1)
            stage = 1
            do { _ = try await networkClient().upload(profile: profile, store: store); XCTFail("wrong UUID must fail") }
            catch ServerSyncError.transfer(let code, _, let retryable) { XCTAssertEqual(code, "profile_receipt_invalid"); XCTAssertFalse(retryable) }
            XCTAssertEqual(try store.profileSyncState(versionID: profile.profileVersionID), "permanent_error")
            XCTAssertEqual(try store.profiles().first?.revision, 0)
            XCTAssertEqual(try store.profiles().first?.contentSha256, profile.contentSha256)
            XCTAssertTrue(try store.pendingProfiles().isEmpty)
        }
    }

    @MainActor
    func testRepeatedRestoreCursorTerminatesWithoutLoopingOrDeletingLocalProfiles() async throws {
        try await networkSource { root, _ in
            let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
            _ = try store.saveProfile(completeDog())
            var calls = 0
            let cursor = UUID().uuidString
            NetworkFaultProtocol.handler = { _ in
                calls += 1
                return .init(body: try JSONSerialization.data(withJSONObject: ["items": [], "nextCursor": cursor]))
            }
            do { _ = try await networkClient().restoreProfiles(into: store); XCTFail("Restore cursor must advance") }
            catch ServerSyncError.transfer(let code, _, _) { XCTAssertEqual(code, "pagination_stalled") }
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(try store.profiles().count, 1)
        }
    }

    @MainActor
    func testRestoreContinuesPastConfirmedRetirementRaceAndKeepsOtherLocalData() async throws {
        try await networkSource { root, source in
            let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
            let profile = try store.saveProfile(completeDog())
            let local = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
            try store.finalize(recording: local, status: "completed", files: [("packet", source, "packets.bin", "application/octet-stream")], syncJSON: Data("{}".utf8))
            let before = try store.artifacts(recordingID: local.id)
            let retiredID = UUID(), activeID = UUID()
            let retiredHash = WoonaStore.sha256(Data(retiredID.uuidString.lowercased().utf8))
            let version: [String: Any] = ["id": profile.profileVersionID.uuidString, "schemaVersion": 1,
                "validationState": "complete", "questionnaire": try JSONSerialization.jsonObject(with: WoonaStore.dogQuestionnaireData(profile.questionnaire)),
                "contentSha256": profile.contentSha256, "clientCreatedAtUtc": profile.updatedAtUTC]
            func summary(_ id: UUID) -> [String: Any] {
                ["id": id.uuidString, "source": "live", "captureStatus": "completed", "ingestStatus": "uploading",
                 "startedAtUtc": "2026-10-27T13:49:03.123456Z", "sessionLabel": "Synthetic mixed restore", "videoRequested": false]
            }
            let detail = summary(activeID).merging(["dogId": profile.id.uuidString, "profileVersion": version,
                "timezone": "UTC", "questionnaireSchemaVersion": 1, "questionnaireValidationState": "complete",
                "sessionQuestionnaire": try JSONSerialization.jsonObject(with: WoonaStore.sessionQuestionnaireData(completeSession())),
                "sync": [:], "artifacts": []]) { _, new in new }
            NetworkFaultProtocol.handler = { request in
                let path = request.url!.path
                let value: [String: Any]
                if path == "/v1/deletions" { value = ["entities": [["kind": "recording", "id_sha256": retiredHash]]] }
                else if path.hasSuffix("/recordings") { value = ["items": [summary(retiredID), summary(activeID)]] }
                else if path == "/v1/recordings/" + retiredID.uuidString { return .init(status: 410, body: Data(#"{"code":"entity_retired"}"#.utf8)) }
                else if path == "/v1/recordings/" + activeID.uuidString { value = detail }
                else { throw ServerSyncError.responseInvalid }
                return .init(body: try JSONSerialization.data(withJSONObject: value))
            }
            let restored = try await networkClient().restoreRecordings(dogIDs: [profile.id], into: store)
            XCTAssertEqual(restored, 1)
            XCTAssertNotNil(try store.recording(id: activeID))
            XCTAssertNil(try store.recording(id: retiredID))
            XCTAssertEqual(try store.artifacts(recordingID: local.id).map(\.id), before.map(\.id))
            for artifact in before { XCTAssertEqual(try WoonaStore.sha256File(store.rootDirectory.appendingPathComponent(artifact.relativePath)), artifact.sha256) }
        }
    }

    @MainActor
    func testRestoreDoesNotSuppressAuthorizationOrServerFailures() async throws {
        try await networkSource { root, _ in
            let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
            let profile = try store.saveProfile(completeDog()), missingID = UUID()
            for status in [401, 403, 503] {
                NetworkFaultProtocol.handler = { request in
                    if request.url!.path == "/v1/deletions" { return .init(body: Data(#"{"entities":[]}"#.utf8)) }
                    if request.url!.path.hasSuffix("/recordings") {
                        let summary: [String: Any] = ["id": missingID.uuidString, "source": "live", "captureStatus": "completed", "ingestStatus": "uploading", "startedAtUtc": "2026-10-27T13:49:03Z", "sessionLabel": "Unknown missing", "videoRequested": false]
                        return .init(body: try JSONSerialization.data(withJSONObject: ["items": [summary]]))
                    }
                    return .init(status: status, body: Data(#"{"code":"entity_retired"}"#.utf8))
                }
                do { _ = try await networkClient().restoreRecordings(dogIDs: [profile.id], into: store); XCTFail("Unconfirmed failure must remain visible: \(status)") }
                catch ServerSyncError.requestFailed(let actual, _) { XCTAssertEqual(actual, status) }
                XCTAssertNotNil(try store.profile(dogID: profile.id, versionID: profile.profileVersionID))
            }
        }
    }

    @MainActor
    func testUnconfirmedMissingRestoreItemsAreVisibleWarningsWhileOtherItemsContinueAndLocalFilesRemain() async throws {
        for status in [404, 410] {
            try await networkSource { root, source in
                let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
                let profile = try store.saveProfile(completeDog())
                let local = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
                try store.finalize(recording: local, status: "completed", files: [("packet", source, "packets.bin", "application/octet-stream")], syncJSON: Data("{}".utf8))
                let before = try store.artifacts(recordingID: local.id)
                let restoredID = UUID()
                let version: [String: Any] = ["id": profile.profileVersionID.uuidString, "schemaVersion": 1,
                    "validationState": "complete", "questionnaire": try JSONSerialization.jsonObject(with: WoonaStore.dogQuestionnaireData(profile.questionnaire)),
                    "contentSha256": profile.contentSha256, "clientCreatedAtUtc": profile.updatedAtUTC]
                func summary(_ id: UUID) -> [String: Any] {
                    ["id": id.uuidString, "source": "live", "captureStatus": "completed", "ingestStatus": "uploading",
                     "startedAtUtc": "2026-10-27T13:49:03.123456Z", "sessionLabel": "Synthetic partial restore", "videoRequested": false]
                }
                let detail = summary(restoredID).merging(["dogId": profile.id.uuidString, "profileVersion": version,
                    "timezone": "UTC", "questionnaireSchemaVersion": 1, "questionnaireValidationState": "complete",
                    "sessionQuestionnaire": try JSONSerialization.jsonObject(with: WoonaStore.sessionQuestionnaireData(completeSession())),
                    "sync": [:], "artifacts": []]) { _, new in new }
                NetworkFaultProtocol.handler = { request in
                    let path = request.url!.path
                    if path == "/v1/deletions" { return .init(body: Data(#"{"entities":[]}"#.utf8)) }
                    if path.hasSuffix("/recordings") { return .init(body: try JSONSerialization.data(withJSONObject: ["items": [summary(local.id), summary(restoredID)]])) }
                    if path == "/v1/recordings/" + local.id.uuidString { return .init(status: status, body: Data(#"{"code":"entity_retired"}"#.utf8)) }
                    return .init(body: try JSONSerialization.data(withJSONObject: detail))
                }
                let client = try networkClient()
                let count = try await client.restoreRecordings(dogIDs: [profile.id], into: store)
                XCTAssertEqual(count, 1)
                XCTAssertEqual(client.restoreWarnings, [.init(kind: "recording", id: local.id, status: status)])
                XCTAssertNotNil(try store.recording(id: restoredID))
                XCTAssertNotNil(try store.recording(id: local.id), "An unmarked 404/410 never authorizes local purge")
                XCTAssertEqual(try store.artifacts(recordingID: local.id).map(\.id), before.map(\.id))
                for artifact in before { XCTAssertEqual(try WoonaStore.sha256File(store.rootDirectory.appendingPathComponent(artifact.relativePath)), artifact.sha256) }
                XCTAssertEqual(try store.retirementCleanupStatus().pendingCount, 0)
            }
        }
    }

    @MainActor
    func testUnconfirmedMissingDogDetailsAndRecordingListKeepLocalProfilesWithWarnings() async throws {
        try await networkSource { root, _ in
            let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
            let profile = try store.saveProfile(completeDog())
            NetworkFaultProtocol.handler = { request in
                if request.url!.path == "/v1/deletions" { return .init(body: Data(#"{"entities":[]}"#.utf8)) }
                if request.url!.path == "/v1/dogs" { return .init(body: try JSONSerialization.data(withJSONObject: ["items": [["id": profile.id.uuidString]]])) }
                return .init(status: 404, body: Data(#"{"code":"not_found"}"#.utf8))
            }
            let client = try networkClient()
            let profiles = try await client.restoreProfiles(into: store)
            XCTAssertEqual(profiles.map(\.id), [profile.id])
            let count = try await client.restoreRecordings(dogIDs: [profile.id], into: store)
            XCTAssertEqual(count, 0)
            XCTAssertEqual(client.restoreWarnings, [.init(kind: "dog", id: profile.id, status: 404)])
            XCTAssertEqual(try store.profile(dogID: profile.id, versionID: profile.profileVersionID)?.contentSha256, profile.contentSha256)
        }
    }

    @MainActor
    func testRestartRecoversOrphanedUploadButPreservesActiveLeaseOffsetsAndFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let profile = try store.saveProfile(completeDog())
        let record = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
        try store.finalize(recording: record, status: "completed", files: [], syncJSON: Data("{}".utf8))
        let artifact = try XCTUnwrap(store.artifacts(recordingID: record.id).first)
        try store.updateArtifactProgress(artifact.id, uploadedBytes: 1, state: "uploading")
        try store.updateRecordingSync(record.id, state: "uploading")
        let files = try store.artifacts(recordingID: record.id)
        XCTAssertEqual(try store.recoverInterruptedUploads(excluding: [record.id]), 0)
        XCTAssertEqual(try store.recording(id: record.id)?.serverSyncState, "uploading")
        let model = AppViewModel(store: store, uiTesting: true)
        XCTAssertNil(model.networkAvailable)
        XCTAssertEqual(try store.recording(id: record.id)?.serverSyncState, "pending")
        XCTAssertTrue(try store.pendingRecordings().contains { $0.id == record.id })
        let after = try store.artifacts(recordingID: record.id)
        XCTAssertEqual(after.map(\.uploadedBytes), files.map(\.uploadedBytes))
        XCTAssertEqual(after.map(\.sha256), files.map(\.sha256))
        XCTAssertEqual(try Data(contentsOf: store.rootDirectory.appendingPathComponent(artifact.relativePath)), Data("{}".utf8))
    }

    @MainActor
    func testProtocolFailureIsPersistedAsActionablePermanentErrorWithoutDeletingRecording() async throws {
        try await networkSource { root, _ in
            let store = try WoonaStore(rootDirectory: root.appendingPathComponent("Woona"))
            let profile = try store.saveProfile(completeDog())
            let record = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
            try store.finalize(recording: record, status: "completed", files: [], syncJSON: Data("{}".utf8))
            let saved = try XCTUnwrap(store.recording(id: record.id))
            NetworkFaultProtocol.handler = { request in
                if request.url!.path == "/v1/deletions" { return .init(body: Data(#"{"entities":[]}"#.utf8)) }
                if request.url!.path.hasSuffix("/sync-status") { return .init(status: 404) }
                if request.url!.path == "/v1/me" { return .init(body: try JSONSerialization.data(withJSONObject: ["deviceId": UUID().uuidString])) }
                if request.httpMethod == "PUT" { return .init(body: Data(#"{"dogRevision":1}"#.utf8)) }
                if request.httpMethod == "HEAD" { return .init(headers: ["Upload-Offset": "-1"]) }
                throw URLError(.badServerResponse)
            }
            do { try await networkClient().upload(recording: saved, profile: profile, store: store); XCTFail("Invalid server position must fail") }
            catch ServerSyncError.transfer(let code, _, _) { XCTAssertEqual(code, "upload_offset_invalid") }
            XCTAssertEqual(try store.profileSyncState(versionID: profile.profileVersionID), "synced") // Manifest receipt confirmed this exact frozen UUID before artifact failure.
            XCTAssertEqual(try store.recording(id: record.id)?.serverSyncState, "permanent_error")
            XCTAssertTrue(try XCTUnwrap(store.recordingSyncError(recordingID: record.id)).contains("upload_offset_invalid"))
            XCTAssertFalse(try store.artifacts(recordingID: record.id).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(for: record).appendingPathComponent("sync.json").path))
        }
    }

    @MainActor
    func testInvalidHeadOffsetsFailBeforeSeekOrPatch() async throws {
        try await networkSource { _, source in
            let values: [String?] = ["-1", "7", nil, "999999999999999999999999999999"]
            for value in values {
                var calls = 0
                NetworkFaultProtocol.handler = { request in
                    calls += 1
                    XCTAssertEqual(request.httpMethod, "HEAD")
                    return .init(headers: value.map { ["Upload-Offset": $0] } ?? [:])
                }
                do {
                    try await networkClient().uploadArtifactBytes(UUID(), file: source, size: 6)
                    XCTFail("Invalid HEAD must fail before converting an offset to UInt64")
                } catch ServerSyncError.transfer(let code, _, _) {
                    XCTAssertTrue(["upload_offset_invalid", "upload_offset_missing"].contains(code))
                }
                XCTAssertEqual(calls, 1)
            }
        }
    }

    @MainActor
    func testPatchCannotGuessMissingOffsetOrAcceptNonadvancingAcknowledgment() async throws {
        try await networkSource { _, source in
            let values: [String?] = ["-1", "0", "2", "7", nil, "overflow"]
            for value in values {
                var progress: [Int64] = []
                var calls = 0
                NetworkFaultProtocol.handler = { request in
                    calls += 1
                    return .init(headers: request.httpMethod == "HEAD" ? ["Upload-Offset": "0"] : value.map { ["Upload-Offset": $0] } ?? [:])
                }
                do {
                    try await networkClient().uploadArtifactBytes(UUID(), file: source, size: 6) { progress.append($0) }
                    XCTFail("Invalid PATCH acknowledgment must not report completion")
                } catch ServerSyncError.transfer(let code, _, _) {
                    XCTAssertTrue(["upload_offset_invalid", "upload_offset_missing"].contains(code))
                }
                XCTAssertEqual(progress, [0])
                XCTAssertEqual(calls, 2)
            }
        }
    }

    @MainActor
    func testConflictRetriesAreBoundedAndRewindsReseekTheFile() async throws {
        try await networkSource { _, source in
            var patches = 0
            NetworkFaultProtocol.handler = { request in
                if request.httpMethod == "HEAD" { return .init(headers: ["Upload-Offset": "0"]) }
                patches += 1
                return .init(status: 409)
            }
            do {
                try await networkClient().uploadArtifactBytes(UUID(), file: source, size: 6)
                XCTFail("A stalled conflict must terminate")
            } catch ServerSyncError.transfer(let code, _, let retryable) {
                XCTAssertEqual(code, "upload_conflict_stalled")
                XCTAssertTrue(retryable)
            }
            XCTAssertEqual(patches, 4)
            var heads = 0
            patches = 0
            NetworkFaultProtocol.handler = { request in
                if request.httpMethod == "HEAD" {
                    heads += 1
                    return .init(headers: ["Upload-Offset": heads == 1 ? "4" : "1"])
                }
                patches += 1
                if patches == 1 {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Upload-Offset"), "4")
                    return .init(status: 409)
                }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Upload-Offset"), "1")
                XCTAssertEqual(NetworkFaultProtocol.body(request), Data("bcdef".utf8))
                return .init(status: 204, headers: ["Upload-Offset": "6"])
            }
            try await networkClient().uploadArtifactBytes(UUID(), file: source, size: 6)
            XCTAssertEqual(patches, 2)
            XCTAssertEqual(try Data(contentsOf: source), Data("abcdef".utf8))
        }
    }

    @MainActor
    func testUploadTimeoutAndEarlyLocalEofPreserveTheSourceAndFailExplicitly() async throws {
        try await networkSource { _, source in
            NetworkFaultProtocol.handler = { _ in throw URLError(.timedOut) }
            do { try await networkClient().uploadArtifactBytes(UUID(), file: source, size: 6); XCTFail("Timeout must fail") }
            catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
            XCTAssertEqual(try Data(contentsOf: source), Data("abcdef".utf8))
            NetworkFaultProtocol.handler = { _ in
                try Data("ab".utf8).write(to: source)
                return .init(headers: ["Upload-Offset": "0"])
            }
            do { try await networkClient().uploadArtifactBytes(UUID(), file: source, size: 6); XCTFail("Truncated source must fail") }
            catch ServerSyncError.transfer(let code, _, let retryable) { XCTAssertEqual(code, "local_artifact_truncated"); XCTAssertFalse(retryable) }
            XCTAssertEqual(try Data(contentsOf: source), Data("ab".utf8))
        }
    }

    @MainActor
    func testDownloadPreservesExistingTargetsAndFinalizesValidFullPartialWithoutNetwork() async throws {
        try await networkSource { root, source in
            let hash = WoonaStore.sha256(Data("abcdef".utf8))
            let client = try networkClient(download: { _ in XCTFail("Existing complete files must not contact network"); throw URLError(.badServerResponse) })
            try await client.download(artifactID: UUID(), to: source, expectedSize: 6, sha256: hash)
            do { try await client.download(artifactID: UUID(), to: source, expectedSize: 6, sha256: String(repeating: "0", count: 64)); XCTFail("Conflicting target must be preserved") }
            catch ServerSyncError.transfer(let code, _, _) { XCTAssertEqual(code, "local_artifact_conflict") }
            XCTAssertEqual(try Data(contentsOf: source), Data("abcdef".utf8))
            let target = root.appendingPathComponent("target.bin")
            try Data("abcdef".utf8).write(to: target.appendingPathExtension("part"))
            try await client.download(artifactID: UUID(), to: target, expectedSize: 6, sha256: hash)
            XCTAssertEqual(try Data(contentsOf: target), Data("abcdef".utf8))
        }
    }

    @MainActor
    func testDownloadRangeValidationAndIgnoredRangeNeverCorruptTheExistingPrefix() async throws {
        try await networkSource { root, _ in
            let hash = WoonaStore.sha256(Data("abcdef".utf8))
            let target = root.appendingPathComponent("target.bin")
            let part = target.appendingPathExtension("part")
            let invalid: [[String: String]] = [[:], ["Content-Range": "bytes 1-4/6"], ["Content-Range": "bytes 2-5/7"],
                ["Content-Range": "bytes 2-5/6", "ETag": "different"], ["Content-Range": "bytes 2-5/6", "Content-Length": "5"],
                ["Content-Range": "bytes 2-5/6", "Content-Encoding": "gzip"]]
            for headers in invalid {
                try Data("ab".utf8).write(to: part)
                let client = try networkClient(download: { request in
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=2-5")
                    let temporary = root.appendingPathComponent(UUID().uuidString)
                    try Data("cdef".utf8).write(to: temporary)
                    return (temporary, HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: headers)!)
                })
                do { try await client.download(artifactID: UUID(), to: target, expectedSize: 6, sha256: hash); XCTFail("Malformed download must fail before touching the prefix") }
                catch ServerSyncError.transfer {}
                XCTAssertEqual(try Data(contentsOf: part), Data("ab".utf8))
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            }
            let ignoredRange = try networkClient(download: { request in
                let temporary = root.appendingPathComponent(UUID().uuidString)
                try Data("abcdef".utf8).write(to: temporary)
                return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "6"])!)
            })
            try await ignoredRange.download(artifactID: UUID(), to: target, expectedSize: 6, sha256: hash)
            XCTAssertEqual(try Data(contentsOf: target), Data("abcdef".utf8))
        }
    }

    @MainActor
    func testDownloadChunkResumptionRetainsConfirmedPrefixAcrossTimeout() async throws {
        try await networkSource { root, _ in
            let block = Data(repeating: 42, count: 8 * 1_024 * 1_024)
            let full = block + Data("end".utf8)
            let target = root.appendingPathComponent("large.bin")
            let part = target.appendingPathExtension("part")
            var calls = 0
            let client = try networkClient(download: { request in
                calls += 1
                if calls == 2 { throw URLError(.timedOut) }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-8388607")
                let temporary = root.appendingPathComponent(UUID().uuidString)
                try block.write(to: temporary)
                return (temporary, HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes 0-8388607/8388611"])!)
            })
            do { try await client.download(artifactID: UUID(), to: target, expectedSize: Int64(full.count), sha256: WoonaStore.sha256(full)); XCTFail("Timeout must not publish a partial target") }
            catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
            XCTAssertEqual(try Data(contentsOf: part), block)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            let resume = try networkClient(download: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=8388608-8388610")
                let temporary = root.appendingPathComponent(UUID().uuidString)
                try Data("end".utf8).write(to: temporary)
                return (temporary, HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes 8388608-8388610/8388611"])!)
            })
            try await resume.download(artifactID: UUID(), to: target, expectedSize: Int64(full.count), sha256: WoonaStore.sha256(full))
            XCTAssertEqual(try Data(contentsOf: target), full)
        }
    }

    @MainActor
    func testDownloadEarlyEofAndHashMismatchDoNotPublishBadFiles() async throws {
        try await networkSource { root, _ in
            let target = root.appendingPathComponent("target.bin")
            let part = target.appendingPathExtension("part")
            try Data("ab".utf8).write(to: part)
            let hash = WoonaStore.sha256(Data("abcdef".utf8))
            let early = try networkClient(download: { request in
                let temporary = root.appendingPathComponent(UUID().uuidString)
                try Data("c".utf8).write(to: temporary)
                return (temporary, HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes 2-5/6"])!)
            })
            do { try await early.download(artifactID: UUID(), to: target, expectedSize: 6, sha256: hash); XCTFail("EOF must fail") }
            catch ServerSyncError.transfer(let code, _, let retryable) { XCTAssertEqual(code, "download_incomplete"); XCTAssertTrue(retryable) }
            XCTAssertEqual(try Data(contentsOf: part), Data("ab".utf8))
            let badHash = try networkClient(download: { request in
                let temporary = root.appendingPathComponent(UUID().uuidString)
                try Data("cdeg".utf8).write(to: temporary)
                return (temporary, HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes 2-5/6"])!)
            })
            do { try await badHash.download(artifactID: UUID(), to: target, expectedSize: 6, sha256: hash); XCTFail("Wrong SHA must fail") }
            catch ServerSyncError.transfer(let code, _, _) { XCTAssertEqual(code, "download_hash_mismatch") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testCaptureReasonPersistsInHistoryAndSurvivesRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var id: UUID!
        do {
            let store = try WoonaStore(rootDirectory: root)
            let dog = try store.saveProfile(completeDog())
            let record = try store.createRecording(profile: dog, source: "live", questionnaire: completeSession())
            id = record.id
            try store.finalize(recording: record, status: "failed", files: [], syncJSON: Data(#"{"captureErrorCode":"gatt_error","captureErrorMessage":"GATT status 8"}"#.utf8))
            try store.updateRecordingSync(id, state: "synced")
            XCTAssertEqual(try store.recording(id: id)?.serverSyncState, "pending", "Unverified artifacts must never produce a confirmed upload")
            for artifact in try store.artifacts(recordingID: id) {
                try store.updateArtifactProgress(artifact.id, uploadedBytes: artifact.sizeBytes, state: "available")
            }
            try store.updateRecordingSync(id, state: "synced")
        }
        let reopened = try WoonaStore(rootDirectory: root)
        let record = try XCTUnwrap(reopened.recording(id: id))
        XCTAssertEqual(record.captureErrorCode, "gatt_error")
        XCTAssertEqual(record.captureErrorMessage, "GATT status 8")
        XCTAssertEqual(record.serverSyncState, "synced")
        XCTAssertEqual(try reopened.recentRecordings(dogID: record.dogID).first?.captureErrorCode, "gatt_error")
    }

    private func localRemovalFixture(_ store: WoonaStore) throws -> (WoonaRecording, ServerRecordingDetail) {
        let dog = try store.saveProfile(completeDog())
        let local = try store.createRecording(profile: dog, source: "live", questionnaire: completeSession())
        let packet = store.directory(for: local).appendingPathComponent("packets.bin")
        try Data("packet data".utf8).write(to: packet)
        try store.finalize(recording: local, status: "failed", files: [("packet", packet, "packets.bin", "application/octet-stream")], syncJSON: Data("{}".utf8))
        let saved = try XCTUnwrap(store.recording(id: local.id))
        let remote = ServerRecordingDetail(id: saved.id, dogId: dog.id,
            profileVersion: .init(id: dog.profileVersionID, schemaVersion: dog.questionnaire.schemaVersion, validationState: "complete", questionnaire: dog.questionnaire,
                                 contentSha256: dog.contentSha256, clientCreatedAtUtc: dog.createdAtUTC, supersededAtUtc: nil),
            source: saved.source, captureStatus: saved.status, ingestStatus: "complete", startedAtUtc: saved.startedAtUTC,
            endedAtUtc: saved.endedAtUTC, timezone: saved.timezone, sessionLabel: saved.sessionLabel,
            questionnaireSchemaVersion: 1, questionnaireValidationState: "complete",
            sessionQuestionnaire: try JSONDecoder().decode(JSONValue.self, from: WoonaStore.sessionQuestionnaireData(saved.questionnaire!)),
            videoRequested: saved.videoRequested, sync: .object([:]),
            artifacts: try store.artifacts(recordingID: saved.id).map { .init(id: $0.id, type: $0.type, fileName: $0.fileName, mimeType: $0.mimeType, sizeBytes: $0.sizeBytes, sha256: $0.sha256, storageStatus: "available") },
            captureErrorCode: "gatt_error", captureErrorMessage: "GATT status 8",
            receiptSha256: String(repeating: "b", count: 64), serverVerifiedAtUtc: "2026-10-26T12:00:00Z")
        return (saved, remote)
    }

    func testFinalizeDoesNotDeleteItsOwnFileThroughAStoragePathAlias() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        let alias = base.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let store = try WoonaStore(rootDirectory: alias)
        let profile = try store.saveProfile(completeDog())
        let record = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
        let packet = store.directory(for: record).appendingPathComponent("packets.bin")
        let original = Data("original packet bytes".utf8)
        try original.write(to: packet)
        try store.finalize(recording: record, status: "completed",
                           files: [("packet", packet.resolvingSymlinksInPath(), "packets.bin", "application/octet-stream")],
                           syncJSON: Data("{}".utf8))
        XCTAssertEqual(try Data(contentsOf: packet), original)
        XCTAssertEqual(try store.artifacts(recordingID: record.id).first { $0.type == "packet" }?.sha256, WoonaStore.sha256(original))
    }

    @MainActor
    func testTerminalImportedSessionWithoutMachineEndCanRemoveVerifiedFilesButNotAnActiveSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        var (record, remote) = try localRemovalFixture(store)
        remote = ServerRecordingDetail(id: remote.id, dogId: remote.dogId, profileVersion: remote.profileVersion,
            source: remote.source, captureStatus: "failed", ingestStatus: remote.ingestStatus, startedAtUtc: remote.startedAtUtc,
            endedAtUtc: nil, timezone: remote.timezone, sessionLabel: remote.sessionLabel,
            questionnaireSchemaVersion: remote.questionnaireSchemaVersion, questionnaireValidationState: remote.questionnaireValidationState,
            sessionQuestionnaire: remote.sessionQuestionnaire, videoRequested: remote.videoRequested, sync: remote.sync,
            artifacts: remote.artifacts, captureErrorCode: remote.captureErrorCode, captureErrorMessage: remote.captureErrorMessage,
            receiptSha256: remote.receiptSha256, serverVerifiedAtUtc: remote.serverVerifiedAtUtc)
        // Model the imported row, not a previously finalized local capture: restore
        // correctly preserves a known local end rather than erasing it with nil.
        do {
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(root.appendingPathComponent("woona.sqlite").path, &database), SQLITE_OK)
            defer { sqlite3_close(database) }
            XCTAssertEqual(sqlite3_exec(database, "UPDATE recordings SET ended_at_utc=NULL WHERE id='\(record.id.uuidString)'", nil, nil, nil), SQLITE_OK)
        }
        _ = try store.restoreRemoteRecording(remote)
        record = try XCTUnwrap(store.recording(id: record.id))
        XCTAssertNil(record.endedAtUTC)
        let model = AppViewModel(store: store, uiTesting: true)
        try await awaitHistoryForTesting(model)
        XCTAssertTrue(model.canRemoveLocalRecording(record))
        try store.markRecording(record.id, status: "recording")
        XCTAssertFalse(model.canRemoveLocalRecording(try XCTUnwrap(store.recording(id: record.id))))
        XCTAssertThrowsError(try store.localRemovalPlan(recordingID: record.id, verifiedRemote: remote))
        try store.markRecording(record.id, status: "failed")
        let plan = try store.localRemovalPlan(recordingID: record.id, verifiedRemote: remote)
        XCTAssertTrue(try plan.removeFiles() > 0)
        XCTAssertNil(try store.recording(id: record.id)?.endedAtUTC)
    }

    func testFreshServerCopyWithMissingCurrentFileNeverConfirmsSafeRemoval() throws {
        let response = Data(#"{"ingestStatus":"complete","transfer":{"status":"stalled","totalBytes":12,"uploadedBytes":12,"verifiedBytes":0,"totalFiles":1,"verifiedFiles":0,"receiptVerified":false,"retryable":true,"nextAction":"restore_missing_file"},"artifacts":[{"id":"00000000-0000-0000-0000-000000000001","fileName":"video.mp4","storageStatus":"missing","verified":false,"sizeBytes":12,"uploadedBytes":12,"errorCode":"stored_file_missing","nextAction":"restore_missing_file"}]}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(ServerTransferStatus.self, from: response).confirmsCurrentServerCopy)
    }

    func testVerifiedLocalRemovalPreservesHistoryCauseAndDownloadMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let (record, remote) = try localRemovalFixture(store)
        _ = try store.restoreRemoteRecording(remote)
        let plan = try store.localRemovalPlan(recordingID: record.id, verifiedRemote: remote)
        XCTAssertTrue(try plan.removeFiles() > 0)
        let history = try XCTUnwrap(store.recording(id: record.id))
        XCTAssertEqual(history.serverSyncState, "synced")
        XCTAssertEqual(history.captureErrorCode, "gatt_error")
        XCTAssertEqual(history.captureErrorMessage, "GATT status 8")
        XCTAssertEqual(history.dogID, record.dogID)
        XCTAssertEqual(try store.missingArtifacts(recordingID: record.id).count, remote.artifacts.count)
        XCTAssertEqual(Set(try store.artifacts(recordingID: record.id).map(\.id)), Set(remote.artifacts.map(\.id)))
        let packet = try XCTUnwrap(store.artifacts(recordingID: record.id).first { $0.type == "packet" })
        let target = store.rootDirectory.appendingPathComponent(packet.relativePath)
        try Data("packet data".utf8).write(to: target)
        XCTAssertEqual(try WoonaStore.sha256File(target), packet.sha256)
        XCTAssertEqual(try store.missingArtifacts(recordingID: record.id).count, remote.artifacts.count - 1)
    }

    func testRemovalPlanCannotDeleteAFileOutsideTheSessionDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let (record, remote) = try localRemovalFixture(store)
        _ = try store.restoreRemoteRecording(remote)
        let plan = try store.localRemovalPlan(recordingID: record.id, verifiedRemote: remote)
        let outside = root.appendingPathComponent("unrelated.txt")
        let bytes = Data("Keep this unrelated file".utf8)
        try bytes.write(to: outside)
        let unsafe = LocalRecordingRemoval(directory: plan.directory, files: plan.files + [.init(url: outside, size: Int64(bytes.count), sha256: WoonaStore.sha256(bytes))])
        XCTAssertThrowsError(try unsafe.removeFiles())
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        XCTAssertTrue(plan.files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    func testLocalRemovalRejectsPendingAndChangedFilesWithoutDeletingOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let (record, remote) = try localRemovalFixture(store)
        XCTAssertThrowsError(try store.localRemovalPlan(recordingID: record.id, verifiedRemote: remote))
        _ = try store.restoreRemoteRecording(remote)
        var unverified = remote
        unverified.receiptSha256 = nil
        XCTAssertThrowsError(try store.localRemovalPlan(recordingID: record.id, verifiedRemote: unverified))
        let plan = try store.localRemovalPlan(recordingID: record.id, verifiedRemote: remote)
        let packet = try XCTUnwrap(plan.files.first { $0.url.lastPathComponent == "packets.bin" })
        try Data("packet datX".utf8).write(to: packet.url)
        XCTAssertThrowsError(try plan.removeFiles())
        XCTAssertTrue(plan.files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        XCTAssertEqual(try String(contentsOf: packet.url, encoding: .utf8), "packet datX")
    }

    @MainActor
    func testIdentityConflictKeepsLocalRecordingAndStopsAutomaticRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); RecordingSyncProtocol.handler = nil }
        let store = try WoonaStore(rootDirectory: root)
        let profile = try store.saveProfile(completeDog())
        let recording = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
        try store.finalize(recording: recording, status: "completed", files: [], syncJSON: Data("{}".utf8))
        let saved = try XCTUnwrap(store.recording(id: recording.id))
        RecordingSyncProtocol.handler = { request in
            if request.url!.path == "/v1/deletions" { return (200, ["entities": []]) }
            if request.url!.path.hasSuffix("/sync-status") { return (404, [:]) }
            if request.url!.path == "/v1/me" { return (200, ["deviceId": UUID().uuidString]) }
            if request.httpMethod == "PUT" { return (409, ["code": "animal_id_already_exists"]) }
            throw ServerSyncError.responseInvalid
        }
        do {
            try await syncClient().upload(recording: saved, profile: profile, store: store)
            XCTFail("Conflicting identity must not be uploaded")
        } catch ServerSyncError.animalIDConflict {}
        XCTAssertEqual(try store.recording(id: recording.id)?.serverSyncState, "permanent_error")
        XCTAssertFalse(try store.artifacts(recordingID: recording.id).isEmpty)
        XCTAssertEqual(try store.profile(dogID: profile.id, versionID: profile.profileVersionID)?.id, profile.id)
    }

    @MainActor
    func testFirstOfflineRecordingAcceptsRevisionBeforeArtifactUploadFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); RecordingSyncProtocol.handler = nil }
        let store = try WoonaStore(rootDirectory: root)
        let profile = try store.saveProfile(completeDog())
        let recording = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
        try store.finalize(recording: recording, status: "completed", files: [], syncJSON: Data("{}".utf8))
        let saved = try XCTUnwrap(store.recording(id: recording.id))
        RecordingSyncProtocol.handler = { request in
            let path = request.url!.path
            if path == "/v1/deletions" { return (200, ["entities": []]) }
            if path.hasSuffix("/sync-status") { return (404, [:]) }
            if path == "/v1/me" { return (200, ["deviceId": UUID().uuidString]) }
            if request.httpMethod == "PUT" { return (200, ["dogRevision": 1]) }
            if request.httpMethod == "HEAD" { return (503, [:]) }
            throw ServerSyncError.responseInvalid
        }
        do {
            try await syncClient().upload(recording: saved, profile: profile, store: store)
            XCTFail("The artifact request must fail")
        } catch ServerSyncError.requestFailed(let status, _) {
            XCTAssertEqual(status, 503)
        }
        XCTAssertEqual(try store.profile(dogID: profile.id, versionID: profile.profileVersionID)?.revision, 1)
        var edited = profile.questionnaire
        edited.numberOrName = "Edited"
        let next = try store.saveProfile(edited, replacing: try XCTUnwrap(store.profile(dogID: profile.id, versionID: profile.profileVersionID)))
        XCTAssertEqual(next.revision, 1)
        XCTAssertEqual(try store.recording(id: recording.id)?.serverSyncState, "retryable_error")
    }

    @MainActor
    func testCompletedServerRecordingRepairsInvalidLocalQuestionnaire() async throws {
        try await checkCompletedRecovery(invalidLocal: true, normalizedHash: false)
    }

    @MainActor
    func testLostCompletionResponseAcceptsServerHashAndArtifactProgress() async throws {
        try await checkCompletedRecovery(invalidLocal: false, normalizedHash: true)
    }

    @MainActor
    func testImportedServerRecordingRebindsArtifactIdentityWithoutChangingFiles() async throws {
        try await checkCompletedRecovery(invalidLocal: false, normalizedHash: false, rekeyedArtifacts: true)
    }

    @MainActor
    func testCompletedRestoreMergesCanonicalPlaceholderWithOriginalPhoneFile() async throws {
        try await checkCompletedRecovery(invalidLocal: false, normalizedHash: false, rekeyedArtifacts: true, canonicalPlaceholder: true)
    }

    @MainActor
    func testArtifactIdentityCannotBeReboundToDifferentBytes() async throws {
        try await checkCompletedRecovery(invalidLocal: false, normalizedHash: false, rekeyedArtifacts: true, corruptServerSHA: true)
    }

    @MainActor
    private func checkCompletedRecovery(invalidLocal: Bool, normalizedHash: Bool, rekeyedArtifacts: Bool = false,
                                        canonicalPlaceholder: Bool = false, corruptServerSHA: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); RecordingSyncProtocol.handler = nil }
        let store = try WoonaStore(rootDirectory: root)
        let profile = try store.saveProfile(completeDog())
        let recording = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
        try store.finalize(recording: recording, status: "completed", files: [], syncJSON: Data("{}".utf8))
        let validSession = try JSONSerialization.jsonObject(with: WoonaStore.sessionQuestionnaireData(completeSession()))
        if invalidLocal {
            var invalid = completeSession(); invalid.operatorName = ""
            let answers = try JSONDecoder().decode(JSONValue.self, from: WoonaStore.sessionQuestionnaireData(invalid))
            try store.acceptServerSession(recordingID: recording.id, questionnaire: answers)
        }
        let saved = try XCTUnwrap(store.recording(id: recording.id))
        let files = try store.artifacts(recordingID: recording.id)
        let remoteIDs = files.map { rekeyedArtifacts ? UUID() : $0.id }
        if canonicalPlaceholder {
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(root.appendingPathComponent("woona.sqlite").path, &database), SQLITE_OK)
            defer { sqlite3_close(database) }
            let sql = """
                INSERT INTO artifacts(id,recording_id,type,file_name,relative_path,mime_type,size_bytes,sha256,
                                      upload_state,uploaded_bytes,created_at_utc)
                SELECT '\(remoteIDs[0].uuidString)',recording_id,type,file_name,'old-server-directory/sync.json',
                       mime_type,size_bytes,sha256,'available',size_bytes,created_at_utc
                FROM artifacts WHERE id='\(files[0].id.uuidString)'
                """
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_changes(database), 1)
        }
        let hash = normalizedHash ? String(repeating: "a", count: 64) : profile.contentSha256
        let version: [String: Any] = ["id": profile.profileVersionID.uuidString, "schemaVersion": 1,
            "validationState": "complete", "questionnaire": try JSONSerialization.jsonObject(with: WoonaStore.dogQuestionnaireData(profile.questionnaire)),
            "contentSha256": hash, "clientCreatedAtUtc": profile.updatedAtUTC]
        let detail: [String: Any] = ["id": saved.id.uuidString, "dogId": profile.id.uuidString, "profileVersion": version,
            "source": "live", "captureStatus": "completed", "ingestStatus": "complete", "startedAtUtc": saved.startedAtUTC,
            "timezone": saved.timezone, "sessionLabel": saved.sessionLabel, "questionnaireSchemaVersion": 1,
            "questionnaireValidationState": "complete", "sessionQuestionnaire": validSession, "videoRequested": false,
            "sync": [:], "artifacts": zip(files, remoteIDs).map { file, id in
                ["id": id.uuidString, "type": file.type, "fileName": file.fileName,
                 "mimeType": file.mimeType, "sizeBytes": file.sizeBytes,
                 "sha256": corruptServerSHA ? String(repeating: "b", count: 64) : file.sha256, "storageStatus": "available"] }]
        RecordingSyncProtocol.handler = { request in
            guard request.httpMethod == "GET" else { throw ServerSyncError.responseInvalid }
            switch request.url!.path {
            case "/v1/deletions": return (200, ["entities": []])
            case "/v1/me": return (200, ["deviceId": UUID().uuidString])
            case "/v1/dogs": return (200, ["items": [["id": profile.id.uuidString]]])
            case "/v1/dogs/" + profile.id.uuidString:
                return (200, ["id": profile.id.uuidString, "numberOrName": profile.numberOrName, "revision": 1,
                              "profileVersion": version, "profileVersions": [version]])
            case "/v1/recordings/" + saved.id.uuidString + "/sync-status": return (200, ["ingestStatus": "complete"])
            case "/v1/recordings/" + saved.id.uuidString: return (200, detail)
            default: throw ServerSyncError.responseInvalid
            }
        }
        if corruptServerSHA {
            do {
                try await syncClient().upload(recording: saved, profile: profile, store: store)
                XCTFail("Different bytes must not be silently accepted")
            } catch WoonaStoreError.invalidData { }
            XCTAssertEqual(try store.artifacts(recordingID: recording.id).map(\.id), files.map(\.id))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(files[0].relativePath)), Data("{}".utf8))
            XCTAssertEqual(try store.recording(id: recording.id)?.serverSyncState, "permanent_error")
            return
        }
        try await syncClient().upload(recording: saved, profile: profile, store: store)
        XCTAssertEqual(try store.profile(dogID: profile.id, versionID: profile.profileVersionID)?.contentSha256, hash)
        XCTAssertEqual(try store.recording(id: recording.id)?.questionnaire?.operatorName, "Operator")
        XCTAssertEqual(try store.recording(id: recording.id)?.serverSyncState, "synced")
        let reconciled = try store.artifacts(recordingID: recording.id)
        XCTAssertEqual(reconciled.map(\.id), remoteIDs)
        XCTAssertTrue(reconciled.allSatisfy { $0.uploadState == "available" && $0.uploadedBytes == $0.sizeBytes })
        XCTAssertEqual(reconciled.map(\.relativePath), files.map(\.relativePath))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(files[0].relativePath)), Data("{}".utf8))
    }

    @MainActor
    private func syncClient() throws -> WoonaServerClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingSyncProtocol.self]
        return try WoonaServerClient(configuration: .init(baseURL: "https://sync.test", wifiOnly: false),
                                     token: "fixture", sessionConfiguration: configuration)
    }

    func testDelayedServerReceiptCannotRollBackDogRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let profile = try store.saveProfile(completeDog())
        try store.setServerRevision(dogID: profile.id, revision: 2)
        try store.setServerRevision(dogID: profile.id, revision: 1)
        XCTAssertEqual(try store.profile(dogID: profile.id, versionID: profile.profileVersionID)?.revision, 2)
    }

    func testRecordingArchiveCarriesCaptureVersionAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let profile = try store.saveProfile(completeDog())
        let recording = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
        let version = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        try store.finalize(recording: recording, status: "completed", files: [], syncJSON: Data("{}".utf8))
        let reopened = try WoonaStore(rootDirectory: root)
        let archive = try reopened.recordingArchive(recordingID: recording.id)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: archive.manifest) as? [String: Any])
        XCTAssertEqual((value["recording"] as? [String: Any])?["appVersion"] as? String, version)
    }

    func testUnchangedAnswersDoNotCreateAnotherProfileVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let original = try store.saveProfile(completeDog())
        var answers = original.questionnaire
        answers.savedAtLocal = "2026-10-09T12:00:00"
        let saved = try store.saveProfile(answers,replacing:original)
        XCTAssertEqual(saved.profileVersionID,original.profileVersionID)
    }

    func testQuestionnairesMatchSharedServerFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("shared/testdata/questionnaires-v2.json"))) as? [[String:Any]])
        for item in cases {
            let data = try JSONSerialization.data(withJSONObject: item["questionnaire"]!)
            let valid: Bool
            if item["kind"] as? String == "dog" { valid = try JSONDecoder().decode(DogQuestionnaire.self,from:data).validate().isValid }
            else { valid = try JSONDecoder().decode(SessionQuestionnaire.self,from:data).validate().isValid }
            XCTAssertEqual(valid,item["valid"] as? Bool)
        }
    }

    func testServerDeletionRemovesOnlyRetiredCompletedUnit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let profile = try store.saveProfile(completeDog())
        let retired = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
        let source = root.appendingPathComponent("capture.bin")
        try Data([1,2,3]).write(to: source)
        try store.finalize(recording: retired, status: "completed", files: [("packet",source,"packets.bin","application/octet-stream")], syncJSON: Data("{}".utf8))
        let keep = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
        let deletion = ServerDeletion(kind: "recording", id_sha256: WoonaStore.sha256(Data(retired.id.uuidString.lowercased().utf8)))
        XCTAssertEqual(try store.applyServerDeletions([deletion]),1)
        XCTAssertNil(try store.recording(id: retired.id))
        XCTAssertNotNil(try store.recording(id: keep.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: retired).path))
        XCTAssertEqual(try store.applyServerDeletions([deletion]),0)
    }

    func testRetirementSQLiteFailurePreservesEveryOriginalFileAndRollsBackOutbox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try WoonaStore(rootDirectory: root)
            let profile = try store.saveProfile(completeDog())
            let record = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
            let source = root.appendingPathComponent("original.bin")
            try Data("only saved capture".utf8).write(to: source)
            try store.finalize(recording: record, status: "completed", files: [("packet", source, "packets.bin", "application/octet-stream")], syncJSON: Data("{}".utf8))
            let before = try store.artifacts(recordingID: record.id)
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(root.appendingPathComponent("woona.sqlite").path, &database), SQLITE_OK)
            defer { sqlite3_close(database) }
            XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER refuse_retirement BEFORE DELETE ON recordings BEGIN SELECT RAISE(ABORT, 'Synthetic retirement DB failure'); END", nil, nil, nil), SQLITE_OK)
            let deletion = ServerDeletion(kind: "recording", id_sha256: WoonaStore.sha256(Data(record.id.uuidString.lowercased().utf8)))
            XCTAssertThrowsError(try store.applyServerDeletions([deletion]))
            XCTAssertNotNil(try store.recording(id: record.id))
            XCTAssertEqual(try store.retirementCleanupStatus().pendingCount, 0)
            for artifact in before { XCTAssertEqual(try WoonaStore.sha256File(root.appendingPathComponent(artifact.relativePath)), artifact.sha256) }
        }
    }

    func testCommittedRetirementRetriesFilesystemFailureAfterRestartWithoutResurrectingMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try WoonaStore(rootDirectory: root)
            let profile = try store.saveProfile(completeDog(), accountID: "inactive-workspace")
            let record = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
            let source = root.appendingPathComponent("original.bin")
            try Data("retired source bytes".utf8).write(to: source)
            try store.finalize(recording: record, status: "completed", files: [("packet", source, "packets.bin", "application/octet-stream")], syncJSON: Data("{}".utf8))
            let active = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
            let deletion = ServerDeletion(kind: "dog", id_sha256: WoonaStore.sha256(Data(profile.id.uuidString.lowercased().utf8)))
            XCTAssertEqual(try store.applyServerDeletions([deletion], accountID: "another-workspace", removeItem: { _ in
                throw WoonaStoreError.invalidData("Synthetic file removal denied")
            }), 1)
            XCTAssertNil(try store.recording(id: record.id))
            XCTAssertNotNil(try store.recording(id: active.id), "A live capture must first stop safely")
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(for: record).path))
            let pending = try store.retirementCleanupStatus()
            XCTAssertEqual(pending.pendingCount, 1)
            XCTAssertTrue(pending.lastError?.contains("Synthetic file removal denied") == true)
            let reopened = try WoonaStore(rootDirectory: root)
            XCTAssertEqual(try reopened.drainLocalDeletionOutbox().pendingCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: record).path))
            XCTAssertNil(try reopened.recording(id: record.id))
            XCTAssertEqual(try reopened.drainLocalDeletionOutbox().pendingCount, 0)
        }
    }

    func testRetirementOutboxRejectsEscapingAndDatabasePathsAndHandlesAlreadyMissingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try WoonaStore(rootDirectory: root)
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(root.appendingPathComponent("woona.sqlite").path, &database), SQLITE_OK)
            defer { sqlite3_close(database) }
            XCTAssertEqual(sqlite3_exec(database, "INSERT INTO local_deletion_outbox(id,relative_path,entry_kind,created_at_utc) VALUES('outside','../outside','file','2026-10-27'),('database','woona.sqlite','file','2026-10-27'),('missing','recordings/already-gone/file.bin','file','2026-10-27')", nil, nil, nil), SQLITE_OK)
            let status = try store.drainLocalDeletionOutbox()
            XCTAssertEqual(status.pendingCount, 2)
            XCTAssertNotNil(status.lastError)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("woona.sqlite").path))
            XCTAssertEqual(try store.profiles().count, 0)
        }
    }

    func testColdStartCaptureRecoveryPreservesSourcesQuestionnaireAndUnknownEndWithoutGuessingWorkingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try WoonaStore(rootDirectory: root)
            let profile = try store.saveProfile(completeDog())
            let original = completeSession()
            let orphan = try store.createRecording(profile: profile, source: "live", questionnaire: original)
            try store.markRecording(orphan.id, status: "recording")
            let live = try store.createRecording(profile: profile, source: "live", questionnaire: original)
            let video = store.directory(for: orphan).appendingPathComponent("video.mp4")
            let source = Data("incomplete source video bytes".utf8)
            try source.write(to: video)
            let unassigned = root.appendingPathComponent("ble_dump_123456.bin")
            try Data("unassigned working data".utf8).write(to: unassigned)
            XCTAssertEqual(try store.recoverUnfinishedCaptures(excluding: [live.id]), 1)
            let recovered = try XCTUnwrap(store.recording(id: orphan.id))
            XCTAssertEqual(recovered.status, "interrupted")
            XCTAssertNil(recovered.endedAtUTC)
            XCTAssertEqual(recovered.questionnaire, original)
            XCTAssertEqual(recovered.captureErrorCode, "process_interrupted")
            XCTAssertEqual(recovered.serverSyncState, "permanent_error")
            XCTAssertTrue(try store.captureRecoveryRequiresReview(orphan.id))
            XCTAssertEqual(try Data(contentsOf: video), source)
            XCTAssertEqual(try store.artifacts(recordingID: orphan.id).map(\.fileName), ["video.mp4"])
            XCTAssertNil(try store.syncJSON(recordingID: orphan.id), "Unknown clock anchors must not become zero-valued sync")
            XCTAssertEqual(try Data(contentsOf: unassigned), Data("unassigned working data".utf8))
            XCTAssertEqual(try store.recording(id: live.id)?.status, "preparing")
            try store.resetFailedSync()
            XCTAssertEqual(try store.recording(id: orphan.id)?.serverSyncState, "permanent_error")
            XCTAssertTrue(try store.pendingRecordings().isEmpty)
            XCTAssertEqual(try store.recoverUnfinishedCaptures(excluding: [live.id]), 0)
        }
    }

    func testReceivedRetirementWaitsForSafeStopAndCompletesOfflineWithoutAnotherServerResponse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try WoonaStore(rootDirectory: root)
            let profile = try store.saveProfile(completeDog(), accountID: "inactive")
            let active = try store.createRecording(profile: profile, source: "live", questionnaire: completeSession())
            let video = store.directory(for: active).appendingPathComponent("video.mp4")
            try Data("live source".utf8).write(to: video)
            let marker = ServerDeletion(kind: "recording", id_sha256: WoonaStore.sha256(Data(active.id.uuidString.lowercased().utf8)))
            XCTAssertEqual(try store.applyServerDeletions([marker], accountID: "other"), 0)
            XCTAssertEqual(try store.retirementCleanupStatus().deferredCount, 1)
            XCTAssertNotNil(try store.recording(id: active.id))
            XCTAssertEqual(try Data(contentsOf: video), Data("live source".utf8))
            try store.markRecording(active.id, status: "interrupted")
            XCTAssertEqual(try store.applyDeferredServerDeletions(), 1)
            XCTAssertNil(try store.recording(id: active.id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: video.path))
            XCTAssertEqual(try store.retirementCleanupStatus().deferredCount, 0)
        }
    }

    func testDeferredDogRetirementSurvivesRestartAndAppliesAfterInterruptedCaptureRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var dogID: UUID?, recordID: UUID?
        do {
            let store = try WoonaStore(rootDirectory: root)
            let dog = try store.saveProfile(completeDog())
            let record = try store.createRecording(profile: dog, source: "live", questionnaire: completeSession())
            dogID = dog.id; recordID = record.id
            try Data("unfinished source".utf8).write(to: store.directory(for: record).appendingPathComponent("packets.bin"))
            let marker = ServerDeletion(kind: "dog", id_sha256: WoonaStore.sha256(Data(dog.id.uuidString.lowercased().utf8)))
            XCTAssertEqual(try store.applyServerDeletions([marker]), 0)
            XCTAssertEqual(try store.retirementCleanupStatus().deferredCount, 1)
        }
        do {
            let reopened = try WoonaStore(rootDirectory: root)
            XCTAssertEqual(try reopened.recoverUnfinishedCaptures(), 1)
            XCTAssertEqual(try reopened.applyDeferredServerDeletions(), 1)
            XCTAssertNil(try reopened.recording(id: XCTUnwrap(recordID)))
            XCTAssertFalse(try reopened.profiles().contains { $0.id == dogID })
            XCTAssertEqual(try reopened.retirementCleanupStatus().deferredCount, 0)
            XCTAssertEqual(try reopened.retirementCleanupStatus().pendingCount, 0)
        }
    }

    func testHeartAnswersReferencesAndRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var store: WoonaStore? = try WoonaStore(rootDirectory: root)
        let profile = try store!.saveProfile(completeDog())
        var session = SessionQuestionnaire()
        session.schemaVersion = 2
        session.sessionLabel = "Heart"
        session.sessionKind = "heart"
        session.plannedActivities = []
        session.surfaces = []
        session.videoRequested = false
        let recording = try store!.createRecording(profile: profile, source: "live", questionnaire: session)
        try store!.finalize(recording: recording, status: "completed", files: [], syncJSON: Data("{}".utf8))
        XCTAssertTrue(try store!.pendingRecordings().isEmpty)
        func unknown(_ key: String) -> HeartAnswer { HeartQuestionnaire.options[key]!.first { $0.key == "unknown" }! }
        var heart = HeartQuestionnaire()
        heart.knownHeartCondition = unknown("knownHeartCondition")
        heart.heartRelevantMedication = unknown("heartRelevantMedication")
        heart.preRecordingState = unknown("preRecordingState")
        heart.actualActivity = unknown("actualActivity")
        heart.acuteHeartRateFactors = [unknown("acuteHeartRateFactors")]
        heart.referenceMethod = unknown("referenceMethod")
        XCTAssertTrue(heart.validate().isValid)
        var invalid = heart
        invalid.acuteHeartRateFactors.append(HeartQuestionnaire.options["acuteHeartRateFactors"]!.first { $0.key == "pain" }!)
        XCTAssertFalse(invalid.validate().isValid)
        invalid = heart
        invalid.referenceMethod = HeartQuestionnaire.options["referenceMethod"]!.first { $0.key == "ecg" }
        XCTAssertFalse(invalid.validate().isValid)
        try store!.saveHeartQuestionnaire(recordingID: recording.id, heart: heart)
        XCTAssertEqual(1, try store!.pendingRecordings().count)
        let bytes = Data("utc,bpm\n2026-10-05T12:00:00Z,120\n".utf8)
        let input = root.appendingPathComponent("target.csv")
        try bytes.write(to: input)
        let metadata = ReferenceMetadata(source: "Polar H10", startedAtUtc: "2026-10-05T12:00:00Z", endedAtUtc: "2026-10-05T12:01:00Z", offsetFromRecordingMs: 0)
        try store!.attachReference(recordingID: recording.id, type: "rr", sourceURL: input, metadata: metadata)
        store = nil
        store = try WoonaStore(rootDirectory: root)
        let restored = try XCTUnwrap(store!.recording(id: recording.id))
        XCTAssertEqual(heart, restored.questionnaire?.heartQuestionnaire)
        let artifact = try XCTUnwrap(store!.artifacts(recordingID: recording.id).first { $0.type == "rr" })
        XCTAssertEqual(metadata, artifact.referenceMetadata)
        let syncArtifact = try XCTUnwrap(store!.artifacts(recordingID: recording.id).first { $0.type == "sync" })
        XCTAssertNil(syncArtifact.referenceMetadata)
        XCTAssertEqual(bytes, try Data(contentsOf: root.appendingPathComponent(artifact.relativePath)))
        XCTAssertEqual(profile.questionnaire, try store!.profile(dogID: profile.id, versionID: profile.profileVersionID)?.questionnaire)
    }

    func testSheetQuestionnaireRoundTripAndDogLink() throws {
        var dog = DogQuestionnaire()
        dog.schemaVersion = 2
        dog.animalId = "финик"
        dog.numberOrName = "Финик"
        dog.species = "собака"
        dog.diagnosesDetails = "Дисплазия"
        XCTAssertTrue(dog.validate().isValid)
        let data = try WoonaStore.dogQuestionnaireData(dog)
        XCTAssertEqual(dog, try JSONDecoder().decode(DogQuestionnaire.self, from: data))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(json["specialistName"] is NSNull)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WoonaStore(rootDirectory: directory)
        let profile = try store.saveProfile(dog)
        var session = SessionQuestionnaire()
        session.schemaVersion = 2
        session.sessionLabel = "2"
        session.plannedActivities = ["Аллюр/движение"]
        session.surfaces = ["Асфальт", "Грунт", "Трава"]
        session.sensorPosition = "Снизу на горле"
        XCTAssertTrue(session.validate().isValid)
        let recording = try store.createRecording(profile: profile, source: "live", questionnaire: session)
        XCTAssertEqual("финик", recording.questionnaire?.animalId)
        XCTAssertEqual(session.surfaces, recording.questionnaire?.surfaces)
        dog.weightKg = .nan
        XCTAssertFalse(dog.validate().isValid)
    }

    func testQuestionnairesMatchAndroidValidationRules() {
        var dog = DogQuestionnaire()
        XCTAssertFalse(dog.validate().isValid)
        dog = completeDog()
        dog.numberOrName = "Rex"
        XCTAssertTrue(dog.validate().isValid)

        dog.weightStatus = "measured"
        XCTAssertEqual("Use >0 and ≤150 kg", dog.validate().errors["weightKg"])
        dog.weightKg = 15.5
        XCTAssertTrue(dog.validate().isValid)

        var session = SessionQuestionnaire()
        XCTAssertFalse(session.validate().isValid)
        session = completeSession()
        session.videoRequested = false
        XCTAssertTrue(session.validate().isValid)
        session.pulseStatus = "measured"
        session.pulseBpm = 70
        XCTAssertNotNil(session.validate().errors["measurementAtUtc"])
    }

    func testSQLiteKeepsImmutableProfileVersionsAndRecordingSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WoonaStore(rootDirectory: directory)
        var dog = completeDog()
        let first = try store.saveProfile(dog)

        dog.numberOrName = "Rex updated"
        let second = try store.saveProfile(dog, replacing: first)
        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(first.profileVersionID, second.profileVersionID)
        XCTAssertNotNil(try store.profile(dogID: first.id, versionID: first.profileVersionID))

        var session = completeSession()
        session.videoRequested = false
        let recording = try store.createRecording(profile: second, source: "replay", questionnaire: session)
        try store.markRecording(recording.id, status: "completed", endedAt: Date())
        XCTAssertEqual(second.profileVersionID, try store.recording(id: recording.id)?.profileVersionID)
        try store.updateRecordingSync(recording.id, state: "permanent_error")
        try store.resetFailedSync()
        XCTAssertEqual("pending", try store.recording(id: recording.id)?.serverSyncState)
    }

    func testServerQuestionnaireJSONIncludesRequiredNulls() throws {
        let dog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: WoonaStore.dogQuestionnaireData(completeDog())) as? [String: Any]
        )
        XCTAssertTrue(dog["breedName"] is NSNull)
        XCTAssertTrue(dog["notes"] is NSNull)

        let session = try XCTUnwrap(
            JSONSerialization.jsonObject(with: WoonaStore.sessionQuestionnaireData(completeSession())) as? [String: Any]
        )
        XCTAssertTrue(session["pulseBpm"] is NSNull)
        XCTAssertTrue(session["measurementAtUtc"] is NSNull)
    }

    func testRemoteProfileCanCreateANewLocalDog() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WoonaStore(rootDirectory: directory)
        let dogID = UUID()
        let versionID = UUID()
        let hash = String(repeating: "a", count: 64)
        let profile = try store.upsertRemoteProfile(
            dogID: dogID,
            profileVersionID: versionID,
            revision: 4,
            questionnaire: completeDog(),
            contentSha256: hash,
            updatedAtUTC: "2026-08-17T12:00:00Z"
        )
        XCTAssertEqual(dogID, profile.id)
        XCTAssertEqual(versionID, profile.profileVersionID)
        XCTAssertEqual(hash, profile.contentSha256)
    }

    func testRemoteRestoreDoesNotOverwriteAnUnsyncedLocalProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WoonaStore(rootDirectory: directory)
        let local = try store.saveProfile(completeDog())
        var remoteDog = completeDog()
        remoteDog.numberOrName = "Remote Rex"
        let restored = try store.upsertRemoteProfile(
            dogID: local.id,
            profileVersionID: UUID(),
            revision: 1,
            questionnaire: remoteDog,
            contentSha256: String(repeating: "c", count: 64),
            updatedAtUTC: "2026-08-17T13:00:00Z"
        )
        XCTAssertEqual(local.profileVersionID, restored.profileVersionID)
        XCTAssertEqual("Rex", restored.numberOrName)
        XCTAssertEqual(1, restored.revision)
    }

    func testRemoteRecordingRestoresMetadataBeforeVerifiedDownload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WoonaStore(rootDirectory: directory)
        let profile = try store.saveProfile(completeDog())
        let recordingID = UUID()
        let artifactID = UUID()
        let remote = ServerRecordingDetail(
            id: recordingID,
            dogId: profile.id,
            profileVersion: .init(
                id: profile.profileVersionID,
                schemaVersion: 1,
                validationState: "complete",
                questionnaire: profile.questionnaire,
                contentSha256: profile.contentSha256,
                clientCreatedAtUtc: profile.createdAtUTC,
                supersededAtUtc: nil
            ),
            source: "live",
            captureStatus: "completed",
            ingestStatus: "complete",
            startedAtUtc: "2026-08-17T12:00:00Z",
            endedAtUtc: "2026-08-17T12:01:00Z",
            timezone: "Europe/Moscow",
            sessionLabel: "Remote",
            questionnaireSchemaVersion: 1,
            questionnaireValidationState: "complete",
            sessionQuestionnaire: .object(["legacy": .bool(true)]),
            videoRequested: false,
            sync: .object(["schemaVersion": .integer(2)]),
            artifacts: [
                ServerArtifact(
                    id: artifactID,
                    type: "sync",
                    fileName: "sync.json",
                    mimeType: "application/json",
                    sizeBytes: 12,
                    sha256: String(repeating: "b", count: 64),
                    storageStatus: "available"
                ),
            ]
        )
        XCTAssertTrue(try store.restoreRemoteRecording(remote))
        let revised = ServerRecordingDetail(
            id: remote.id, dogId: remote.dogId, profileVersion: remote.profileVersion,
            source: remote.source, captureStatus: remote.captureStatus, ingestStatus: remote.ingestStatus,
            startedAtUtc: remote.startedAtUtc, endedAtUtc: remote.endedAtUtc, timezone: remote.timezone,
            sessionLabel: "Corrected server label", questionnaireSchemaVersion: remote.questionnaireSchemaVersion,
            questionnaireValidationState: remote.questionnaireValidationState, sessionQuestionnaire: remote.sessionQuestionnaire,
            videoRequested: remote.videoRequested, sync: remote.sync, artifacts: remote.artifacts,
            questionnaireRevision: 2
        )
        XCTAssertFalse(try store.restoreRemoteRecording(revised))
        XCTAssertEqual("Corrected server label", try store.recording(id: recordingID)?.sessionLabel)
        XCTAssertEqual(2, try store.recording(id: recordingID)?.questionnaireRevision)
        XCTAssertEqual("synced", try store.recording(id: recordingID)?.serverSyncState)
        XCTAssertNil(try store.recording(id: recordingID)?.questionnaire)
        XCTAssertEqual([artifactID], try store.missingArtifacts(recordingID: recordingID).map(\.id))
    }

    @MainActor
    func testFailedRecordingExportsAllLocalArtifactsAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: WoonaStore? = try WoonaStore(rootDirectory: directory)
        let profile = try store!.saveProfile(completeDog())
        let session = completeSession()
        let recording = try store!.createRecording(profile: profile, source: "live", questionnaire: session)
        let samples = [
            ("packet", "packets.bin"), ("packet_timeline", "packet_timeline.bin"),
            ("raw", "raw_fragments.binlog"), ("diagnostic", "diagnostics.log"),
            ("csv", "channel.csv"), ("video", "video.mp4"), ("imported_source", "imported.bin"),
        ]
        let files = try samples.map { type, name -> (type: String, source: URL, name: String, mime: String) in
            let source = directory.appendingPathComponent(name)
            try Data("fixture-\(name)".utf8).write(to: source)
            return (type, source, name, "application/octet-stream")
        }
        try store!.finalize(recording: recording, status: "interrupted", files: files, syncJSON: Data("{\"schemaVersion\":2}".utf8))
        try store!.updateRecordingSync(recording.id, state: "permanent_error", error: NSError(domain: "upload", code: 401,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 401: invalid_bearer_token"]))
        var editedDog = completeDog()
        editedDog.numberOrName = "Updated dog"
        _ = try store!.saveProfile(editedDog, replacing: profile)
        store = nil
        let reopened = try WoonaStore(rootDirectory: directory)
        let metadata = try reopened.recordingArchive(recordingID: recording.id)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata.manifest) as? [String: Any])
        XCTAssertEqual("Rex", (manifest["profile"] as? [String: Any])?["numberOrName"] as? String)
        XCTAssertEqual("permanent_error", (manifest["recording"] as? [String: Any])?["serverSyncState"] as? String)
        XCTAssertEqual("Morning", ((manifest["recording"] as? [String: Any])?["questionnaire"] as? [String: Any])?["sessionLabel"] as? String)
        XCTAssertEqual(2, (manifest["synchronization"] as? [String: Any])?["schemaVersion"] as? Int)
        XCTAssertEqual(8, metadata.files.count)
        let viewModel = AppViewModel(store: reopened)
        try await awaitHistoryForTesting(viewModel)
        XCTAssertTrue(viewModel.exportableRecordingIDs.contains(recording.id))
        XCTAssertEqual("HTTP 401: invalid_bearer_token", viewModel.recordingSyncErrors[recording.id])
        viewModel.shareRecording(recording.id)
        // Native file-coordination cold startup on a loaded CI simulator can exceed five seconds.
        for _ in 0..<600 where viewModel.preparedExport == nil && viewModel.exportPhase != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let prepared = try XCTUnwrap(viewModel.preparedExport, viewModel.errorMessage ?? "ZIP did not open the share sheet")
        let archive = try XCTUnwrap(prepared.urls.first)
        let bytes = try Data(contentsOf: archive)
        XCTAssertEqual([0x50, 0x4b], Array(bytes.prefix(2)))
        for name in samples.map({ $0.1 }) + ["sync.json", "manifest.json"] {
            XCTAssertNotNil(bytes.range(of: Data(name.utf8)), "ZIP central directory omitted \(name)")
        }
        // XCTest owns the proof even when Xcode runs in an ephemeral cloned simulator.
        let acceptance = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.zip-archive")
        acceptance.name = "woona-export-acceptance.zip"
        acceptance.lifetime = .keepAlways
        add(acceptance)
        viewModel.clearPreparedExport()
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual("permanent_error", try reopened.recording(id: recording.id)?.serverSyncState)
        XCTAssertEqual(8, try reopened.artifacts(recordingID: recording.id).count)
        for file in metadata.files {
            XCTAssertEqual(file.sha256, WoonaStore.sha256(try Data(contentsOf: file.url)))
        }
    }

    @MainActor
    func testSavedPacketAndCsvExportsWorkWithoutCurrentCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WoonaStore(rootDirectory: directory)
        let profile = try store.saveProfile(completeDog())
        let recording = try store.createRecording(profile: profile, source: "replay", questionnaire: completeSession())
        let packet = Data(makeTestPacket(counter: 1, timerMillis: 50, measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[10, 20]])]))
        let source = directory.appendingPathComponent("source.bin")
        try packet.write(to: source)
        try store.finalize(recording: recording, status: "completed", files: [("packet", source, "packets.bin", "application/octet-stream")],
                           syncJSON: Data("{}".utf8))
        let viewModel = AppViewModel(store: store)
        viewModel.prepareExport(.channelCsv)
        XCTAssertNotNil(viewModel.exportPhase)
        viewModel.prepareExport(.packetDump) // A second tap must not replace an export already in progress.
        for _ in 0..<600 where viewModel.preparedExport == nil && viewModel.exportPhase != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let csv = try XCTUnwrap(viewModel.preparedExport?.urls.first, viewModel.errorMessage ?? "CSV not prepared")
        let text = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertTrue(text.contains("axl_sensor_2_ch_1"))
        XCTAssertTrue(text.contains(",50,50,10"))
        viewModel.clearPreparedExport()
        XCTAssertFalse(FileManager.default.fileExists(atPath: csv.path))
        viewModel.prepareExport(.packetDump)
        for _ in 0..<600 where viewModel.preparedExport == nil && viewModel.exportPhase != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let exported = try XCTUnwrap(viewModel.preparedExport?.urls.first)
        XCTAssertEqual(packet, try Data(contentsOf: exported))
        viewModel.clearPreparedExport()
        XCTAssertEqual(2, try store.artifacts(recordingID: recording.id).count)
    }

    func testRecordingArchiveRejectsEmptyAndChangedFilesAndReportsMissingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WoonaStore(rootDirectory: directory)
        let profile = try store.saveProfile(completeDog())
        let recording = try store.createRecording(profile: profile, source: "replay", questionnaire: completeSession())
        XCTAssertThrowsError(try store.recordingArchive(recordingID: recording.id))
        try store.markRecording(recording.id, status: "failed")
        XCTAssertThrowsError(try store.recordingArchive(recordingID: recording.id))
        let video = directory.appendingPathComponent("source.mp4")
        try Data("original-video".utf8).write(to: video)
        try store.finalize(recording: recording, status: "failed", files: [("video", video, "video.mp4", "video/mp4")],
                           syncJSON: Data("{\"cameraError\":\"interrupted\"}".utf8))
        let original = try store.recordingArchive(recordingID: recording.id)
        let localVideo = try XCTUnwrap(original.files.first { $0.url.lastPathComponent == "video.mp4" }).url
        try Data("corrupt-video".utf8).write(to: localVideo)
        let output = directory.appendingPathComponent("export", isDirectory: true)
        XCTAssertThrowsError(try original.create(in: output))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        XCTAssertEqual(Data("corrupt-video".utf8), try Data(contentsOf: localVideo))
        try FileManager.default.removeItem(at: localVideo)
        let partial = try store.recordingArchive(recordingID: recording.id)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: partial.manifest) as? [String: Any])
        XCTAssertEqual(["video.mp4"], manifest["missingFiles"] as? [String])
        XCTAssertEqual(["sync.json"], partial.files.map { $0.url.lastPathComponent })
        for _ in 0..<12 { _ = try store.createRecording(profile: profile, source: "replay", questionnaire: completeSession()) }
        XCTAssertEqual(10, try store.recentRecordings(dogID: profile.id).count)
        XCTAssertEqual(13, try store.recentRecordings(dogID: profile.id, limit: nil).count)
    }

    func testDogAccountPersistsAndManualLinkKeepsAllSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let unassigned = try store.saveProfile(completeDog())
        let other = try store.saveProfile(completeDog(), accountID: "other")
        let recording = try store.createRecording(profile: unassigned, source: "replay", questionnaire: completeSession())
        try store.finalize(recording: recording, status: "completed", files: [], syncJSON: Data("{}".utf8))
        let artifacts = try store.artifacts(recordingID: recording.id)
        try store.linkDog(dogID: unassigned.id, accountID: "field")
        try store.linkDog(dogID: unassigned.id, accountID: "field")
        XCTAssertThrowsError(try store.linkDog(dogID: unassigned.id, accountID: "other"))
        let reopened = try WoonaStore(rootDirectory: root)
        XCTAssertEqual(try reopened.profile(dogID: unassigned.id, versionID: unassigned.profileVersionID)?.accountID, "field")
        XCTAssertEqual(try reopened.profile(dogID: other.id, versionID: other.profileVersionID)?.accountID, "other")
        XCTAssertEqual(try reopened.recentRecordings(dogID: unassigned.id).map(\.id), [recording.id])
        for artifact in artifacts { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(artifact.relativePath).path)) }
        var revised = completeDog(); revised.numberOrName = "Renamed"
        let updated = try store.saveProfile(revised, replacing: try XCTUnwrap(reopened.profile(dogID: unassigned.id, versionID: unassigned.profileVersionID)), accountID: "other")
        XCTAssertEqual(updated.accountID, "field")
        let unrelatedDeletion = ServerDeletion(kind: "dog", id_sha256: WoonaStore.sha256(Data(other.id.uuidString.lowercased().utf8)))
        XCTAssertEqual(try store.applyServerDeletions([unrelatedDeletion], accountID: "field"), 0)
        XCTAssertNil(try store.profile(dogID: other.id, versionID: other.profileVersionID), "Authoritative retirement applies to inactive accounts too")
    }

    func testRemoteExplicitDogLinkAdoptsUnassignedLocalDogWithoutRemovingSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let dog = try store.saveProfile(completeDog())
        let recording = try store.createRecording(profile: dog, source: "replay", questionnaire: completeSession())
        let adopted = try store.upsertRemoteProfile(dogID: dog.id, profileVersionID: dog.profileVersionID,
            revision: 1, questionnaire: dog.questionnaire, contentSha256: dog.contentSha256,
            updatedAtUTC: dog.updatedAtUTC, accountID: "field")
        XCTAssertEqual(adopted.accountID, "field")
        XCTAssertNotNil(try store.recording(id: recording.id))
        XCTAssertThrowsError(try store.upsertRemoteProfile(dogID: dog.id, profileVersionID: dog.profileVersionID,
            revision: 2, questionnaire: dog.questionnaire, contentSha256: dog.contentSha256,
            updatedAtUTC: dog.updatedAtUTC, accountID: "other"))
    }

    func testIncompleteRemoteRecordingRestoresQuestionnaireWithoutTakingUploadOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let dog = try store.saveProfile(completeDog())
        let local = try store.createRecording(profile: dog, source: "replay", questionnaire: completeSession())
        try store.finalize(recording: local, status: "completed", files: [], syncJSON: Data("{}".utf8))
        var canonical = completeSession(); canonical.sessionLabel = "Server correction"
        let answers = try JSONDecoder().decode(JSONValue.self, from: WoonaStore.sessionQuestionnaireData(canonical))
        func detail(_ id: UUID) -> ServerRecordingDetail {
            ServerRecordingDetail(id: id, dogId: dog.id,
                profileVersion: .init(id: dog.profileVersionID, schemaVersion: 1, validationState: "complete",
                    questionnaire: dog.questionnaire, contentSha256: dog.contentSha256,
                    clientCreatedAtUtc: dog.createdAtUTC, supersededAtUtc: nil),
                source: "replay", captureStatus: "completed", ingestStatus: "uploading",
                startedAtUtc: local.startedAtUTC, endedAtUtc: "2026-10-10T12:00:00Z", timezone: "UTC",
                sessionLabel: canonical.sessionLabel, questionnaireSchemaVersion: 1,
                questionnaireValidationState: "complete", sessionQuestionnaire: answers,
                videoRequested: false, sync: .object([:]), artifacts: [], questionnaireRevision: 2)
        }
        let remoteID = UUID()
        XCTAssertTrue(try store.restoreRemoteRecording(detail(remoteID)))
        let remote = try XCTUnwrap(store.recording(id: remoteID))
        XCTAssertEqual(remote.serverSyncState, "remote")
        XCTAssertEqual(remote.questionnaire, canonical)
        XCTAssertEqual(remote.questionnaireRevision, 2)
        XCTAssertFalse(try store.pendingRecordings().contains { $0.id == remoteID })
        try store.saveSessionQuestionnaire(recordingID: remoteID, questionnaire: canonical, revision: 3)
        XCTAssertEqual(try store.recording(id: remoteID)?.serverSyncState, "remote")
        XCTAssertFalse(try store.pendingRecordings().contains { $0.id == remoteID })
        XCTAssertFalse(try store.restoreRemoteRecording(detail(local.id)))
        XCTAssertEqual(try store.recording(id: local.id)?.serverSyncState, "pending")
        XCTAssertEqual(try store.recording(id: local.id)?.sessionLabel, canonical.sessionLabel)
        XCTAssertEqual(try store.pendingRecordings().map(\.id), [local.id])
    }

    func testSessionEditQueuesAnswersAndPreservesCaptureFieldsAndFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let profile = try store.saveProfile(completeDog(), accountID: "field")
        let recording = try store.createRecording(profile: profile, source: "replay", questionnaire: completeSession())
        try store.finalize(recording: recording, status: "completed", files: [], syncJSON: Data("{}".utf8))
        let syncBefore = try store.syncJSON(recordingID: recording.id)
        var edited = completeSession(); edited.sessionLabel = "Corrected"
        try store.saveSessionQuestionnaire(recordingID: recording.id, questionnaire: edited)
        let pending = try XCTUnwrap(store.recording(id: recording.id))
        XCTAssertTrue(pending.questionnaireDirty)
        XCTAssertEqual(pending.questionnaireRevision, 1)
        XCTAssertEqual(pending.sessionLabel, "Corrected")
        XCTAssertEqual(try store.pendingRecordings().map(\.id), [recording.id])
        XCTAssertEqual(try store.syncJSON(recordingID: recording.id), syncBefore)
        edited.videoRequested.toggle()
        XCTAssertThrowsError(try store.saveSessionQuestionnaire(recordingID: recording.id, questionnaire: edited))
        edited.videoRequested.toggle()
        try store.saveSessionQuestionnaire(recordingID: recording.id, questionnaire: edited, revision: 2)
        XCTAssertFalse(try XCTUnwrap(store.recording(id: recording.id)).questionnaireDirty)
        XCTAssertEqual(try store.recording(id: recording.id)?.questionnaireRevision, 2)
    }

    @MainActor
    func testAccountNormalizationAndRevisionConflictUseDisplayedRevision() async throws {
        XCTAssertEqual(try WoonaServerClient.normalizedAccount("  Field_A-1  "), "field_a-1")
        XCTAssertNil(try WoonaServerClient.normalizedAccount(" "))
        for invalid in ["../account", "аccount", "-account", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try WoonaServerClient.normalizedAccount(invalid))
        }
        defer { RecordingSyncProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingSyncProtocol.self]
        let client = try WoonaServerClient(configuration: .init(baseURL: "https://sync.test", wifiOnly: false, accountID: "field"), token: "test", sessionConfiguration: configuration)
        RecordingSyncProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Woona-Account"), "field")
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertTrue(request.url!.path.hasSuffix("/questionnaire"))
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["expectedRevision"] as? Int, 2)
            return (409, ["message": "Revision conflict"])
        }
        do {
            _ = try await client.updateQuestionnaire(recordingID: UUID(), questionnaire: completeSession(), expectedRevision: 2)
            XCTFail("Stale revision must fail")
        } catch ServerSyncError.requestFailed(let status, _) { XCTAssertEqual(status, 409) }
    }

    @MainActor
    func testImportedServerQuestionnaireConflictPreservesDraftAndLostResponseRetryReconciles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { RecordingSyncProtocol.handler = nil; try? FileManager.default.removeItem(at: root) }
        @MainActor func exerciseFixture() async throws {
            let store = try WoonaStore(rootDirectory: root)
            let dog = try store.saveProfile(completeDog())
            let id = UUID()
            var original = completeSession(); original.videoRequested = false
            var desired = original; desired.sessionLabel = "My retained draft"
            let profileJSON = try JSONSerialization.jsonObject(with: WoonaStore.encoder.encode(dog.questionnaire))
            func detail(_ answers: SessionQuestionnaire, revision: Int) throws -> [String: Any] {
                ["id": id.uuidString, "dogId": dog.id.uuidString,
                 "profileVersion": ["id": dog.profileVersionID.uuidString, "schemaVersion": 1, "validationState": "complete",
                    "questionnaire": profileJSON, "contentSha256": dog.contentSha256, "clientCreatedAtUtc": dog.createdAtUTC],
                 "source": "replay", "captureStatus": "completed", "ingestStatus": "complete",
                 "startedAtUtc": "2026-10-25T10:00:00Z", "endedAtUtc": NSNull(), "timezone": "UTC",
                 "sessionLabel": answers.sessionLabel, "questionnaireSchemaVersion": 1, "questionnaireValidationState": "complete",
                 "sessionQuestionnaire": try JSONSerialization.jsonObject(with: WoonaStore.sessionQuestionnaireData(answers)),
                 "videoRequested": false, "sync": [:], "artifacts": [], "questionnaireRevision": revision]
            }
            let initial = try JSONDecoder().decode(ServerRecordingDetail.self, from: JSONSerialization.data(withJSONObject: detail(original, revision: 1)))
            XCTAssertTrue(try store.restoreRemoteRecording(initial))
            let displayed = try XCTUnwrap(store.recording(id: id)); XCTAssertNil(displayed.endedAtUTC)
            let syncBefore = try store.syncJSON(recordingID: id)
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RecordingSyncProtocol.self]
            let client = try WoonaServerClient(configuration: .init(baseURL: "https://sync.test", wifiOnly: false), token: "fixture", sessionConfiguration: configuration)
            let model = AppViewModel(store: store, uiTesting: true, questionnaireClientFactory: { _ in client })
            XCTAssertTrue(model.canEditQuestionnaire(displayed))
            @MainActor func awaitEditorReady() async {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(5))
                while !model.canEditQuestionnaire(displayed), clock.now < deadline { await Task.yield() }
                XCTAssertTrue(model.canEditQuestionnaire(displayed), "Queued sync housekeeping must finish before another user save")
            }
            var committed = original; committed.sessionLabel = "Another operator's edit"
            var reads = 0; var writes = 0
            RecordingSyncProtocol.handler = { request in
                if request.httpMethod == "PUT" { writes += 1; return (409, ["code": "questionnaire_revision_conflict"]) }
                reads += 1; return (200, try detail(committed, revision: 4))
            }
            do { try await model.saveSessionQuestionnaire(desired, displayedRecording: displayed); XCTFail("Different server answers need review") }
            catch let conflict as QuestionnaireRevisionConflict { XCTAssertEqual(conflict.revision, 4); XCTAssertEqual(conflict.questionnaire.sessionLabel, committed.sessionLabel) }
            XCTAssertEqual(try store.recording(id: id)?.questionnaire, original)
            XCTAssertEqual(desired.sessionLabel, "My retained draft")
            // A real second tap is a later MainActor turn. Let the scheduled sync
            // housekeeping finish; the production editing guard must stay enforced.
            await awaitEditorReady()
            // Simulate the previous request committing before its response was lost.
            committed = desired; committed.savedAtLocal = "server-timestamp"
            try await model.saveSessionQuestionnaire(desired, displayedRecording: displayed)
            XCTAssertEqual(reads, 2); XCTAssertEqual(writes, 2)
            XCTAssertEqual(try store.recording(id: id)?.questionnaire, committed)
            XCTAssertEqual(try store.recording(id: id)?.questionnaireRevision, 4)
            XCTAssertNil(try store.recording(id: id)?.endedAtUTC)
            XCTAssertEqual(try store.syncJSON(recordingID: id), syncBefore, "Revision recovery must not overwrite the original capture manifest")
            await awaitEditorReady()
        }
        try await exerciseFixture()
    }

    private func completeDog() -> DogQuestionnaire {
        var dog = DogQuestionnaire()
        dog.numberOrName = "Rex"
        dog.shelterOrPlace = "Shelter 1"
        dog.breedStatus = "unknown"
        dog.size = "unknown"
        dog.ageStatus = "unknown"
        dog.ageSource = "unknown"
        dog.sex = "unknown"
        dog.sterilizationStatus = "unknown"
        dog.weightStatus = "unknown"
        dog.bodyConditionStatus = "unable"
        dog.muscleMass = "unable"
        dog.neckCircumferenceStatus = "not_measured"
        dog.coatLength = "unknown"
        dog.undercoat = "unknown"
        dog.shavedAreasStatus = "unknown"
        dog.observedSigns = ["none"]
        dog.diagnosesStatus = "unknown"
        dog.housing = "unknown"
        dog.walksStatus = "unknown"
        dog.cohabitants = "unknown"
        dog.shelterPermission = "unknown"
        dog.notesStatus = "none"
        return dog
    }

    @MainActor
    func testRealLoopbackDownloadUsesTwoBoundedRangesAndVerifiedTargetNeedsNoRequest() async throws {
        let server = try LoopbackArtifactHTTPServer(payload: Data(repeating: 0x35, count: 8 * 1_024 * 1_024) + Data("loopback-tail".utf8))
        defer { server.stop() }
        let baseURL = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        let probe = URLSession(configuration: configuration)
        defer { probe.invalidateAndCancel() }
        var head = URLRequest(url: try XCTUnwrap(URL(string: baseURL + "/v1/artifacts/\(server.artifactID.uuidString)/content")))
        head.httpMethod = "HEAD"
        let (headBody, headResponse) = try await probe.data(for: head)
        XCTAssertTrue(headBody.isEmpty)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), String(server.payload.count))
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"), "\"\(server.sha256)\"")
        let client = try WoonaServerClient(configuration: .init(baseURL: baseURL, wifiOnly: false),
                                          token: "loopback-fixture", sessionConfiguration: configuration)
        try await client.download(artifactID: server.artifactID, to: server.target, expectedSize: Int64(server.payload.count), sha256: server.sha256)
        XCTAssertEqual(try WoonaStore.sha256File(server.target), server.sha256)
        XCTAssertEqual(try Data(contentsOf: server.target).count, server.payload.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.target.appendingPathExtension("part").path))
        XCTAssertEqual(server.requests.map(\.method), ["HEAD", "GET", "GET"])
        let requests = server.requests.filter { $0.method == "GET" }
        XCTAssertEqual(requests.map(\.path), [server.route, server.route])
        XCTAssertEqual(requests.map(\.range), ["bytes=0-8388607", "bytes=8388608-\(server.payload.count - 1)"])
        XCTAssertEqual(requests.map(\.encoding), ["identity", "identity"])
        XCTAssertEqual(requests.last?.ifRange, "\"\(server.sha256)\"")
        try await client.download(artifactID: server.artifactID, to: server.target, expectedSize: Int64(server.payload.count), sha256: server.sha256)
        XCTAssertEqual(server.requests.count, 3, "An already verified target must not make a network request")
    }

    @MainActor
    func testRealLoopbackDownloadResumesExistingPrefixWithRangeAndIfRange() async throws {
        let server = try LoopbackArtifactHTTPServer(payload: Data(repeating: 0x62, count: 512 * 1_024 + 19))
        defer { server.stop() }
        let baseURL = try await server.start()
        let prefixLength = 131_073
        try server.payload.prefix(prefixLength).write(to: server.target.appendingPathExtension("part"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let client = try WoonaServerClient(configuration: .init(baseURL: baseURL, wifiOnly: false),
                                          token: "loopback-fixture", sessionConfiguration: configuration)
        try await client.download(artifactID: server.artifactID, to: server.target, expectedSize: Int64(server.payload.count), sha256: server.sha256)
        XCTAssertEqual(try WoonaStore.sha256File(server.target), server.sha256)
        XCTAssertEqual(try Data(contentsOf: server.target), server.payload)
        XCTAssertEqual(server.requests.map(\.range), ["bytes=\(prefixLength)-\(server.payload.count - 1)"])
        XCTAssertEqual(server.requests.first?.ifRange, "\"\(server.sha256)\"")
        XCTAssertEqual(server.requests.first?.encoding, "identity")
    }

    @MainActor
    func testRealLoopbackMalformedRangePreservesPrefixAndExistingOriginal() async throws {
        let server = try LoopbackArtifactHTTPServer(payload: Data(repeating: 0x73, count: 128 * 1_024 + 7), malformedRange: true)
        defer { server.stop() }
        let baseURL = try await server.start()
        let part = server.target.appendingPathExtension("part")
        let prefix = Data(server.payload.prefix(37))
        try prefix.write(to: part)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let client = try WoonaServerClient(configuration: .init(baseURL: baseURL, wifiOnly: false),
                                          token: "loopback-fixture", sessionConfiguration: configuration)
        do {
            try await client.download(artifactID: server.artifactID, to: server.target, expectedSize: Int64(server.payload.count), sha256: server.sha256)
            XCTFail("A response with the wrong Content-Range must not publish a target")
        } catch ServerSyncError.transfer(let code, _, _) { XCTAssertEqual(code, "download_range_invalid") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.target.path))
        XCTAssertEqual(try Data(contentsOf: part), prefix)
        let original = Data("Preserve this independent local original".utf8)
        try original.write(to: server.target)
        do {
            try await client.download(artifactID: server.artifactID, to: server.target, expectedSize: Int64(server.payload.count), sha256: server.sha256)
            XCTFail("An existing conflicting local original must not be overwritten")
        } catch ServerSyncError.transfer(let code, _, _) { XCTAssertEqual(code, "local_artifact_conflict") }
        XCTAssertEqual(try Data(contentsOf: server.target), original)
        XCTAssertEqual(server.requests.count, 1)
    }

    private func completeSession() -> SessionQuestionnaire {
        var session = SessionQuestionnaire()
        session.sessionLabel = "Morning"
        session.operatorName = "Operator"
        session.activityGroup = "stationary"
        session.activityType = "rest"
        session.location = "indoors"
        session.surface = "concrete"
        session.airTemperatureStatus = "not_measured"
        session.sensorPosition = "dorsal_neck"
        session.collarTightness = "snug"
        session.preMeasurementState = "rest"
        session.pulseStatus = "not_measured"
        session.respirationStatus = "not_measured"
        session.bodyTemperatureStatus = "not_measured"
        return session
    }
}

/// A single-route, loopback-only fixture exercising URLSession's real socket and
/// download-task temporary files. It never contacts a configured or external API.
private final class LoopbackArtifactHTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let range: String?
        let ifRange: String?
        let encoding: String?
    }
    let payload: Data
    let sha256: String
    let artifactID = UUID()
    let target: URL
    var route: String { "/prefix/v1/artifacts/\(artifactID.uuidString)/content" }
    private let root: URL
    private let malformedRange: Bool
    private let listener: NWListener
    private let queue = DispatchQueue(label: "woona.tests.loopback-http")
    private let lock = NSLock()
    private var ready: CheckedContinuation<UInt16, Error>?
    private var listenerState = "setup"
    private var connections: [NWConnection] = []
    private var recorded: [Request] = []
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }

    init(payload: Data, malformedRange: Bool = false) throws {
        self.payload = payload
        self.malformedRange = malformedRange
        sha256 = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("woona-loopback-" + UUID().uuidString)
        target = root.appendingPathComponent("download.bin")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func start() async throws -> String {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            lock.lock(); ready = continuation; lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.lock.lock(); self.listenerState = String(describing: state); self.lock.unlock()
                switch state {
                case .ready:
                    if let port = self.listener.port { _ = self.finishReady(.success(port.rawValue)) }
                    else { _ = self.finishReady(.failure(self.startupFailure("ready without a port", startedAt: startedAt))) }
                case .failed(let error):
                    _ = self.finishReady(.failure(self.startupFailure(error.localizedDescription, startedAt: startedAt)))
                case .cancelled:
                    _ = self.finishReady(.failure(self.startupFailure("listener cancelled", startedAt: startedAt)))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.lock(); self.connections.append(connection); self.lock.unlock()
                connection.start(queue: self.queue)
                self.receive(connection, buffered: Data())
            }
            listener.start(queue: queue)
            // Simulator service startup can exceed five seconds while Xcode boots
            // multiple test clones. This budget is only for the test listener;
            // the HTTP request deadline and every download assertion stay strict.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self else { return }
                if self.finishReady(.failure(self.startupFailure("20-second bootstrap deadline", startedAt: startedAt))) { self.listener.cancel() }
            }
        }
        return "http://127.0.0.1:\(port)/prefix"
    }

    private func startupFailure(_ reason: String, startedAt: TimeInterval) -> Error {
        lock.lock()
        let state = listenerState, requestCount = recorded.count, connectionCount = connections.count
        lock.unlock()
        let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - startedAt)
        return WoonaStoreError.invalidData("Loopback test listener startup failed: \(reason); state=\(state), elapsed=\(elapsed)s, requests=\(requestCount), connections=\(connectionCount)")
    }

    private func finishReady(_ result: Result<UInt16, Error>) -> Bool {
        lock.lock(); let continuation = ready; ready = nil; lock.unlock()
        continuation?.resume(with: result)
        return continuation != nil
    }

    func stop() {
        listener.cancel()
        lock.lock(); let active = connections; connections = []; lock.unlock()
        active.forEach { $0.cancel() }
        try? FileManager.default.removeItem(at: root)
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffered
            if let bytes { buffer.append(bytes) }
            guard buffer.count <= 16_384 else { connection.cancel(); return }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { self.respond(connection, header: buffer) }
            else if !complete && error == nil { self.receive(connection, buffered: buffer) }
            else { connection.cancel() }
        }
    }

    private func respond(_ connection: NWConnection, header: Data) {
        guard let text = String(data: header, encoding: .utf8) else { connection.cancel(); return }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3 else { connection.cancel(); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<separator]).lowercased()] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        let method = String(first[0]), path = String(first[1])
        lock.lock()
        recorded.append(Request(method: method, path: path, range: headers["range"], ifRange: headers["if-range"], encoding: headers["accept-encoding"]))
        lock.unlock()
        guard path == route, ["GET", "HEAD"].contains(method) else {
            return send(connection, status: "404 Not Found", fields: [:], body: Data())
        }
        var fields = ["ETag": "\"\(sha256)\"", "Content-Encoding": "identity", "Accept-Ranges": "bytes", "Content-Type": "application/octet-stream"]
        if method == "HEAD" {
            fields["Content-Length"] = String(payload.count)
            return send(connection, status: "200 OK", fields: fields, body: Data())
        }
        guard let range = headers["range"], range.hasPrefix("bytes=") else {
            return send(connection, status: "200 OK", fields: fields, body: payload)
        }
        let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]),
              start >= 0, start <= end, end < payload.count else {
            return send(connection, status: "416 Range Not Satisfiable", fields: fields, body: Data())
        }
        fields["Content-Range"] = malformedRange
            ? "bytes \(start + 1)-\(end + 1)/\(payload.count + 1)"
            : "bytes \(start)-\(end)/\(payload.count)"
        send(connection, status: "206 Partial Content", fields: fields, body: payload.subdata(in: start..<(end + 1)))
    }

    private func send(_ connection: NWConnection, status: String, fields: [String: String], body: Data) {
        var headers = fields
        if headers["Content-Length"] == nil { headers["Content-Length"] = String(body.count) }
        headers["Connection"] = "close"
        let prefix = "HTTP/1.1 \(status)\r\n" + headers.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        connection.send(content: Data(prefix.utf8) + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { error in if error != nil { connection.cancel() } })
    }
}

private final class HangingRetirementProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stopped = 0
    nonisolated(unsafe) private static var owner: String?
    private var didStop = false
    @discardableResult
    static func reset() -> String {
        lock.lock(); defer { lock.unlock() }
        let owner = UUID().uuidString
        Self.owner = owner; stopped = 0
        return owner
    }
    static var stoppedCount: Int { lock.lock(); defer { lock.unlock() }; return stopped }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "retirement.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard !didStop else { return }
        didStop = true
        // Requests from another test can receive stopLoading after this reset.
        // The immutable synthetic owner travels in the request's URL prefix.
        if request.url?.pathComponents.dropFirst().first == Self.owner { Self.stopped += 1 }
    }
}

private final class RecordingSyncProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sync.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw ServerSyncError.responseInvalid }
            let (status, value) = try handler(request)
            let data = try JSONSerialization.data(withJSONObject: value)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class NetworkFaultProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
    }
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Reply)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "network.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let reply = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65_536)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 65_536)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

// Provenance is real Git DDL, not a current database with a reduced user_version.
// iOS was first published at schema 5 (73a0beb); source for versions 1–4 is absent.
private enum HistoricalIOSSchema: Int, CaseIterable {
    case initial5, reference5, appVersion5, accounts6, profileQueue7, retirement8
    var version: Int { self.rawValue < 3 ? 5 : self.rawValue == 3 ? 6 : self.rawValue == 4 ? 7 : 8 }
    var hasReference: Bool { rawValue >= Self.reference5.rawValue }
    var hasAppVersion: Bool { rawValue >= Self.appVersion5.rawValue }
    var hasAccount: Bool { rawValue >= Self.accounts6.rawValue }
    var hasProfileQueue: Bool { rawValue >= Self.profileQueue7.rawValue }
    var hasRetirementQueue: Bool { self == .retirement8 }
    var sql: String {
        var sql = """
        CREATE TABLE IF NOT EXISTS dogs(
        id TEXT PRIMARY KEY,current_profile_version_id TEXT NOT NULL,
        number_or_name TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,
        created_at_utc TEXT NOT NULL,updated_at_utc TEXT NOT NULL,
        archived_at_utc TEXT
        );
        CREATE TABLE IF NOT EXISTS dog_profile_versions(
        id TEXT PRIMARY KEY,dog_id TEXT NOT NULL REFERENCES dogs(id),
        schema_version INTEGER NOT NULL,validation_state TEXT NOT NULL,
        questionnaire_json TEXT NOT NULL,content_sha256 TEXT NOT NULL,
        client_created_at_utc TEXT NOT NULL,superseded_at_utc TEXT
        );
        CREATE TABLE IF NOT EXISTS recordings(
        id TEXT PRIMARY KEY,dog_id TEXT NOT NULL REFERENCES dogs(id),
        dog_profile_version_id TEXT NOT NULL REFERENCES dog_profile_versions(id),
        source TEXT NOT NULL CHECK(source IN ('live','replay')),
        status TEXT NOT NULL CHECK(status IN ('preparing','recording','completed','failed','interrupted')),
        session_label TEXT NOT NULL,video_requested INTEGER NOT NULL,
        started_at_utc TEXT NOT NULL,ended_at_utc TEXT,timezone TEXT NOT NULL,
        questionnaire_json TEXT NOT NULL,relative_directory TEXT NOT NULL UNIQUE,
        server_sync_state TEXT NOT NULL DEFAULT 'pending'
        );
        CREATE TABLE IF NOT EXISTS recording_sync(
        recording_id TEXT PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
        sync_json TEXT NOT NULL,updated_at_utc TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS artifacts(
        id TEXT PRIMARY KEY,recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
        type TEXT NOT NULL,file_name TEXT NOT NULL,relative_path TEXT NOT NULL,
        mime_type TEXT NOT NULL,size_bytes INTEGER NOT NULL,sha256 TEXT NOT NULL,
        upload_state TEXT NOT NULL DEFAULT 'pending',uploaded_bytes INTEGER NOT NULL DEFAULT 0,
        created_at_utc TEXT NOT NULL,UNIQUE(recording_id,relative_path)
        );
        CREATE TABLE IF NOT EXISTS server_sync_state(
        recording_id TEXT PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
        state TEXT NOT NULL DEFAULT 'pending',attempt_count INTEGER NOT NULL DEFAULT 0,
        next_retry_at_utc TEXT,last_error_code TEXT,last_error_message TEXT,
        server_receipt_sha256 TEXT,updated_at_utc TEXT NOT NULL
        );
        """
        // reference5: c6a6a5a; appVersion5: 0109d3a; accounts6: d584261.
        if hasReference { sql += "ALTER TABLE artifacts ADD COLUMN reference_metadata_json TEXT;" }
        if hasAppVersion { sql += "ALTER TABLE recordings ADD COLUMN app_version TEXT;" }
        if hasAccount {
            sql += "ALTER TABLE dogs ADD COLUMN account_id TEXT;"
            sql += "ALTER TABLE recordings ADD COLUMN questionnaire_revision INTEGER NOT NULL DEFAULT 1;"
            sql += "ALTER TABLE recordings ADD COLUMN questionnaire_dirty INTEGER NOT NULL DEFAULT 0;"
        }
        // profileQueue7: f83fa3b; retirement8: 860cc2b.
        if hasProfileQueue {
            sql += "CREATE TABLE profile_sync_state(profile_version_id TEXT PRIMARY KEY REFERENCES dog_profile_versions(id) ON DELETE CASCADE,state TEXT NOT NULL DEFAULT 'pending',last_error TEXT,updated_at_utc TEXT NOT NULL);"
        }
        if hasRetirementQueue {
            sql += "CREATE TABLE local_deletion_outbox(id TEXT PRIMARY KEY,relative_path TEXT NOT NULL,entry_kind TEXT NOT NULL CHECK(entry_kind IN ('directory','file')),created_at_utc TEXT NOT NULL,last_error TEXT,UNIQUE(relative_path,entry_kind));"
            sql += "CREATE TABLE deferred_retirements(kind TEXT NOT NULL,id_sha256 TEXT NOT NULL,received_at_utc TEXT NOT NULL,PRIMARY KEY(kind,id_sha256));"
        }
        return sql + "PRAGMA user_version=\(version);"
    }
}

private func fixtureSQL(_ database: OpaquePointer?, _ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw WoonaStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

private func fixtureSQLText(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

private func fixtureScalar(_ database: OpaquePointer?, _ sql: String) throws -> String {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw WoonaStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return "" }
    return sqlite3_column_type(statement, 0) == SQLITE_NULL ? "" : String(cString: sqlite3_column_text(statement, 0))
}

@MainActor
private func awaitHistoryForTesting(_ model: AppViewModel, allowFailure: Bool = false) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 20
    while (model.isHistoryLoading || model.isLocalRecoveryRunning), ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertFalse(model.isHistoryLoading, "History read did not finish")
    XCTAssertFalse(model.isLocalRecoveryRunning, "Local recovery did not finish")
    if !allowFailure { XCTAssertNil(model.historyLoadError) }
}


@MainActor
private func awaitStorageCheck(_ model: AppViewModel) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while model.serverStorageCheck == "checking", ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertNotEqual(model.serverStorageCheck, "checking")
}


private final class RestoreConcurrencyProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var body: Data; var delay: TimeInterval = 0 }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> Reply)?
    nonisolated(unsafe) private static var active = 0
    nonisolated(unsafe) private static var peak = 0
    nonisolated(unsafe) private static var finished = 0
    nonisolated(unsafe) private static var generation: UInt64 = 0
    private var generation: UInt64 = 0
    private var settled = false
    private var work: DispatchWorkItem?
    static func reset(_ handler: ((URLRequest) throws -> Reply)?) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler; active = 0; peak = 0; finished = 0; generation &+= 1
    }
    static var maximumActive: Int { lock.lock(); defer { lock.unlock() }; return peak }
    static var finishedCount: Int { lock.lock(); defer { lock.unlock() }; return finished }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "restore.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); self.generation = Self.generation; let handler = Self.handler; Self.active += 1; Self.peak = max(Self.peak, Self.active); Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let reply = try handler(request)
            let work = DispatchWorkItem { [self] in
                guard settle(completed: true) else { return }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.body)
                client?.urlProtocolDidFinishLoading(self)
            }
            Self.lock.lock(); self.work = work; let cancelled = settled; Self.lock.unlock()
            if cancelled { work.cancel() } else { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: work) }
        } catch { if settle(completed: false) { client?.urlProtocol(self, didFailWithError: error) } }
    }
    private func settle(completed: Bool) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard !settled else { return false }
        settled = true; work = nil
        guard generation == Self.generation else { return false }
        Self.active -= 1
        if completed { Self.finished += 1 }
        return true
    }
    override func stopLoading() {
        _ = settle(completed: false)
        Self.lock.lock(); let work = self.work; self.work = nil; Self.lock.unlock()
        work?.cancel()
    }
}
