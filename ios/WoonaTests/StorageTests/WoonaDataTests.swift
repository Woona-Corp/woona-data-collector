import XCTest
import SQLite3
@testable import Woona

final class WoonaDataTests: XCTestCase {
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
        try store.finalize(recording: local, status: "failed", files: [("packet", packet, "application/octet-stream")], syncJSON: Data("{}".utf8))
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
    func testTerminalImportedSessionWithoutMachineEndCanRemoveVerifiedFilesButNotAnActiveSession() throws {
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
        XCTAssertNotNil(try store.profile(dogID: other.id, versionID: other.profileVersionID))
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
