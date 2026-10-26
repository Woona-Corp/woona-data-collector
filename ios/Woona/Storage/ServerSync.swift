import Foundation
import Security

struct ServerConfiguration: Equatable {
    var baseURL: String
    var wifiOnly: Bool
    var accountID: String? = nil
}

struct ServerTransferStatus: Decodable {
    struct Transfer: Decodable {
        let status: String
        let totalBytes: Int64
        let uploadedBytes: Int64
        let verifiedBytes: Int64
        let totalFiles: Int
        let verifiedFiles: Int
        let receiptVerified: Bool
        let lastProgressAtUtc: String?
        let retryable: Bool
        let nextAction: String
    }
    struct Artifact: Decodable, Identifiable {
        let id: UUID
        let fileName: String
        let storageStatus: String
        let verified: Bool?
        let sizeBytes: Int64
        let uploadedBytes: Int64
        let errorCode: String?
        let errorMessage: String?
        let nextAction: String
    }
    struct Labeling: Decodable {
        let eligible: Bool
        let exclusionReasons: [String]
        let taskStatus: String
    }
    let ingestStatus: String
    let transfer: Transfer?
    let artifacts: [Artifact]?
    let labeling: Labeling?
    var confirmsCurrentServerCopy: Bool {
        transfer?.receiptVerified == true && artifacts?.isEmpty == false &&
        artifacts?.allSatisfy { $0.storageStatus == "available" && $0.verified == true && $0.errorCode == nil } == true
    }
}

struct ServerRecordingSummary: Codable, Identifiable, Equatable {
    let id: UUID
    let source: String
    let captureStatus: String
    let ingestStatus: String
    let startedAtUtc: String
    let endedAtUtc: String?
    let sessionLabel: String
    let videoRequested: Bool
    var captureErrorCode: String? = nil
    var captureErrorMessage: String? = nil
}

struct ServerArtifact: Decodable, Identifiable {
    let id: UUID
    let type: String
    let fileName: String
    let mimeType: String
    let sizeBytes: Int64
    let sha256: String
    let storageStatus: String
    var referenceMetadata: ReferenceMetadata? = nil
}

struct ServerProfileVersion: Decodable, Identifiable {
    let id: UUID
    let schemaVersion: Int
    let validationState: String
    let questionnaire: DogQuestionnaire
    let contentSha256: String
    let clientCreatedAtUtc: String
    let supersededAtUtc: String?
}

struct ServerRecordingDetail: Decodable {
    let id: UUID
    let dogId: UUID
    let profileVersion: ServerProfileVersion
    let source: String
    let captureStatus: String
    let ingestStatus: String
    let startedAtUtc: String
    let endedAtUtc: String?
    let timezone: String
    let sessionLabel: String
    let questionnaireSchemaVersion: Int
    let questionnaireValidationState: String
    let sessionQuestionnaire: JSONValue
    let videoRequested: Bool
    let sync: JSONValue
    let artifacts: [ServerArtifact]
    var appVersion: String? = nil
    var accountId: String? = nil
    var questionnaireRevision: Int? = nil
    var captureErrorCode: String? = nil
    var captureErrorMessage: String? = nil
    var receiptSha256: String? = nil
    var serverVerifiedAtUtc: String? = nil
}

enum JSONValue: Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Int64.self) { self = .integer(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([JSONValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let decoded): try value.encode(decoded)
        case .integer(let decoded): try value.encode(decoded)
        case .number(let decoded): try value.encode(decoded)
        case .string(let decoded): try value.encode(decoded)
        case .array(let decoded): try value.encode(decoded)
        case .object(let decoded): try value.encode(decoded)
        }
    }
}

struct ServerProfileReceipt: Decodable {
    let dogRevision: Int
    var profileVersion: ServerProfileVersion? = nil
}

struct ServerDeletion: Decodable {
    let kind: String
    let id_sha256: String
}

enum ServerSyncError: LocalizedError {
    case invalidURL
    case tokenMissing
    case responseInvalid
    case requestFailed(Int, String)
    case animalIDConflict

    static func responseError(status: Int, data: Data) -> ServerSyncError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = body?["detail"] as? [String: Any] ?? body
        if status == 409, detail?["code"] as? String == "animal_id_already_exists" { return .animalIDConflict }
        let code = detail?["code"] as? String
        let message = detail?["message"] as? String ?? body?["detail"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
        return .requestFailed(status, code.map { "\($0): \(message)" } ?? message)
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Server URL is invalid"
        case .tokenMissing: "Server token is missing"
        case .responseInvalid: "Server response is invalid"
        case .animalIDConflict: "This animal ID already belongs to another profile. Check the account, restore profiles and select the existing dog. Local recordings are preserved; changing the name does not release the ID."
        case .requestFailed(let status, let message): "Server returned \(status): \(message)"
        }
    }
}

final class KeychainTokenStore {
    private let service = "com.woona.apps.server"
    private let account = "bearer-token"

    func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func save(_ token: String) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if token.isEmpty {
            SecItemDelete(key as CFDictionary)
            return
        }
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            key as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ServerSyncError.requestFailed(Int(updateStatus), "Unable to update token")
        }
        var value = key
        value[kSecValueData as String] = data
        value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(value as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ServerSyncError.requestFailed(Int(status), "Unable to store token")
        }
    }
}

@MainActor
final class WoonaServerClient {
    private let baseURL: URL
    private let token: String
    private let accountID: String?
    private let session: URLSession

    init(configuration: ServerConfiguration, token: String, sessionConfiguration: URLSessionConfiguration = .default) throws {
        guard let url = URL(string: configuration.baseURL), url.host != nil,
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw ServerSyncError.invalidURL
        }
        guard !token.isEmpty else { throw ServerSyncError.tokenMissing }
        self.baseURL = url
        self.token = token
        self.accountID = configuration.accountID
        sessionConfiguration.allowsCellularAccess = !configuration.wifiOnly
        sessionConfiguration.allowsExpensiveNetworkAccess = !configuration.wifiOnly
        sessionConfiguration.waitsForConnectivity = true
        self.session = URLSession(configuration: sessionConfiguration)
    }

    static func normalizedAccount(_ input: String) throws -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil else {
            throw WoonaStoreError.invalidData("Account: use 1–64 Latin letters, digits, dots, underscores or hyphens")
        }
        return value.lowercased()
    }

    func applyAccount() async throws {
        guard let accountID else { return }
        struct Account: Decodable { let identifier: String }
        let _: Account = try await json(method: "PUT", path: "/v1/accounts/\(accountID)", body: Data("{}".utf8), as: Account.self)
    }

    func linkDog(_ dogID: UUID) async throws {
        guard let accountID else { throw WoonaStoreError.invalidData("Select an account first") }
        _ = try await rawRequest(method: "PUT", path: "/v1/dogs/\(dogID.uuidString)/account",
                                 body: JSONSerialization.data(withJSONObject: ["accountId": accountID]), contentType: "application/json")
    }

    func checkConnection() async throws {
        _ = try await rawRequest(method: "GET", path: "/health/ready", body: nil, contentType: "application/json")
        _ = try await rawRequest(method: "GET", path: "/v1/dogs?limit=1", body: nil, contentType: "application/json")
    }

    func syncStatus(_ recordingID: UUID) async throws -> ServerTransferStatus {
        try await json(method: "GET", path: "/v1/recordings/\(recordingID.uuidString)/sync-status", body: nil, as: ServerTransferStatus.self)
    }

    func recordingDetail(_ recordingID: UUID) async throws -> ServerRecordingDetail {
        try await json(method: "GET", path: "/v1/recordings/\(recordingID.uuidString)", body: nil, as: ServerRecordingDetail.self)
    }

    func updateQuestionnaire(recordingID: UUID, questionnaire: SessionQuestionnaire, expectedRevision: Int) async throws -> ServerRecordingDetail {
        let answers = try JSONSerialization.jsonObject(with: WoonaStore.sessionQuestionnaireData(questionnaire))
        let body = try JSONSerialization.data(withJSONObject: ["expectedRevision": expectedRevision, "questionnaire": answers])
        return try await json(method: "PUT", path: "/v1/recordings/\(recordingID.uuidString)/questionnaire", body: body, as: ServerRecordingDetail.self)
    }

    func deviceID() async throws -> UUID {
        struct Me: Decodable { let deviceId: UUID }
        return try await json(method: "GET", path: "/v1/me", body: Optional<Data>.none, as: Me.self).deviceId
    }

    func upload(profile: DogProfile, store: WoonaStore) async throws -> Int {
        try store.applyServerDeletions(try await deletions(), accountID: accountID)
        let questionnaire = try JSONSerialization.jsonObject(with: WoonaStore.dogQuestionnaireData(profile.questionnaire))
        let payload: [String: Any] = [
            "dog": [
                "id": profile.id.uuidString,
                "numberOrName": profile.numberOrName,
                "expectedRevision": profile.revision,
            ],
            "profileVersion": [
                "id": profile.profileVersionID.uuidString,
                "schemaVersion": profile.questionnaire.schemaVersion,
                "validationState": "complete",
                "questionnaire": questionnaire,
                "contentSha256": profile.contentSha256,
                "clientCreatedAtUtc": profile.updatedAtUTC,
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        let receipt: ServerProfileReceipt = try await json(
            method: "PUT",
            path: "/v1/dogs/\(profile.id.uuidString)/profile-versions/\(profile.profileVersionID.uuidString)",
            body: body,
            as: ServerProfileReceipt.self
        )
        if let accepted = receipt.profileVersion { try store.acceptServerProfile(dogID: profile.id, version: accepted) }
        return receipt.dogRevision
    }

    func deletions() async throws -> [ServerDeletion] {
        struct Result: Decodable { let entities: [ServerDeletion] }
        return try await json(method: "GET", path: "/v1/deletions", body: Optional<Data>.none, as: Result.self).entities
    }

    func restoreProfiles(into store: WoonaStore) async throws -> [DogProfile] {
        struct Dog: Decodable {
            let id: UUID
            let numberOrName: String
            let revision: Int
            let accountId: String?
            let updatedAtUtc: String?
            let profileVersion: ServerProfileVersion
            let profileVersions: [ServerProfileVersion]
        }
        struct Summary: Decodable { let id: UUID }
        struct Page: Decodable { let items: [Summary]; let nextCursor: UUID? }
        var cursor: UUID?
        repeat {
            let suffix = cursor.map { "?limit=200&cursor=\($0.uuidString)" } ?? "?limit=200"
            let page: Page = try await json(method: "GET", path: "/v1/dogs\(suffix)", body: Optional<Data>.none, as: Page.self)
            for summary in page.items {
                let dog: Dog = try await json(
                    method: "GET",
                    path: "/v1/dogs/\(summary.id.uuidString)",
                    body: Optional<Data>.none,
                    as: Dog.self
                )
                _ = try store.upsertRemoteProfile(
                    dogID: dog.id,
                    profileVersionID: dog.profileVersion.id,
                    revision: dog.revision,
                    questionnaire: dog.profileVersion.questionnaire,
                    contentSha256: dog.profileVersion.contentSha256,
                    updatedAtUTC: dog.updatedAtUtc ?? dog.profileVersion.clientCreatedAtUtc,
                    accountID: dog.accountId
                )
                for version in dog.profileVersions where version.id != dog.profileVersion.id {
                    try store.restoreRemoteProfileVersion(dogID: dog.id, version: version)
                }
            }
            cursor = page.nextCursor
        } while cursor != nil
        try store.applyServerDeletions(try await deletions(), accountID: accountID)
        return try store.profiles().filter { $0.accountID == accountID }
    }

    func recordings(dogID: UUID, limit: Int = 10) async throws -> [ServerRecordingSummary] {
        struct Page: Decodable { let items: [ServerRecordingSummary]; let nextCursor: UUID? }
        let page: Page = try await json(
            method: "GET",
            path: "/v1/dogs/\(dogID.uuidString)/recordings?limit=\(limit)",
            body: Optional<Data>.none,
            as: Page.self
        )
        return page.items
    }

    @discardableResult
    func restoreRecordings(dogIDs: [UUID], into store: WoonaStore) async throws -> Int {
        struct Page: Decodable { let items: [ServerRecordingSummary]; let nextCursor: UUID? }
        var restored = 0
        for dogID in dogIDs {
            var cursor: UUID?
            repeat {
                let suffix = cursor.map { "?limit=200&cursor=\($0.uuidString)" } ?? "?limit=200"
                let page: Page = try await json(
                    method: "GET",
                    path: "/v1/dogs/\(dogID.uuidString)/recordings\(suffix)",
                    body: Optional<Data>.none,
                    as: Page.self
                )
                for summary in page.items {
                    let detail: ServerRecordingDetail = try await json(
                        method: "GET",
                        path: "/v1/recordings/\(summary.id.uuidString)",
                        body: Optional<Data>.none,
                        as: ServerRecordingDetail.self
                    )
                    if try store.restoreRemoteRecording(detail) { restored += 1 }
                }
                cursor = page.nextCursor
            } while cursor != nil
        }
        return restored
    }

    func upload(recording: WoonaRecording, profile: DogProfile, store: WoonaStore, onProgress: (() -> Void)? = nil) async throws {
        do {
            try store.applyServerDeletions(try await deletions(), accountID: accountID)
            guard try store.recording(id: recording.id) != nil else { return }
            let existing: RecordingUploadStatus?
            do { existing = try await json(method: "GET", path: "/v1/recordings/\(recording.id.uuidString)/sync-status", body: nil, as: RecordingUploadStatus.self) }
            catch ServerSyncError.requestFailed(404, _) { existing = nil }
            if recording.questionnaireDirty, existing != nil, let questionnaire = recording.questionnaire {
                let accepted = try await updateQuestionnaire(recordingID: recording.id, questionnaire: questionnaire, expectedRevision: recording.questionnaireRevision)
                let canonical = try JSONDecoder().decode(SessionQuestionnaire.self, from: JSONEncoder().encode(accepted.sessionQuestionnaire))
                try store.saveSessionQuestionnaire(recordingID: recording.id, questionnaire: canonical, revision: accepted.questionnaireRevision ?? 1)
            }
            let alreadyComplete = existing?.ingestStatus == "complete"
            if alreadyComplete {
                let canonical: ServerRecordingDetail = try await json(method:"GET",path:"/v1/recordings/\(recording.id.uuidString)",body:Optional<Data>.none,as:ServerRecordingDetail.self)
                try store.acceptServerProfile(dogID: canonical.dogId, version: canonical.profileVersion)
                _ = try await restoreProfiles(into:store)
                _ = try store.restoreRemoteRecording(canonical)
            } else {
                guard recording.questionnaire?.readyForSync != false else { return }
                guard profile.questionnaire.validate().isValid,
                      recording.questionnaire?.validate().isValid == true else {
                    throw WoonaStoreError.invalidData("Анкета не прошла локальную проверку")
                }
            }
            guard let recording = try store.recording(id: recording.id),
                  let profile = try store.profile(dogID: recording.dogID, versionID: recording.profileVersionID) else {
                throw ServerSyncError.responseInvalid
            }
            try store.updateRecordingSync(recording.id, state: "uploading")
            let allArtifacts = try store.artifacts(recordingID: recording.id)
            let artifacts = alreadyComplete ? allArtifacts.filter { ["ecg", "heart_rate", "rr"].contains($0.type) && $0.uploadState != "available" } : allArtifacts
            guard (!allArtifacts.isEmpty),
                  let syncData = try store.syncJSON(recordingID: recording.id),
                  var sync = try JSONSerialization.jsonObject(with: syncData) as? [String: Any] else {
                throw ServerSyncError.responseInvalid
            }
            let captureDeviceID = try await deviceID()
            let profileJSON = try JSONSerialization.jsonObject(with: WoonaStore.dogQuestionnaireData(profile.questionnaire))
            guard let questionnaire = recording.questionnaire else { throw ServerSyncError.responseInvalid }
            let sessionJSON = try JSONSerialization.jsonObject(with: WoonaStore.sessionQuestionnaireData(questionnaire))
            let captureErrorCode = sync.removeValue(forKey: "captureErrorCode")
            let captureErrorMessage = sync.removeValue(forKey: "captureErrorMessage")
            let artifactPayloads = try artifacts.map { artifact in
                [
                    "id": artifact.id.uuidString,
                    "type": artifact.type,
                    "fileName": artifact.fileName,
                    "mimeType": artifact.mimeType,
                    "sizeBytes": artifact.sizeBytes,
                    "sha256": artifact.sha256,
                    "clientCreatedAtUtc": recording.endedAtUTC ?? recording.startedAtUTC,
                    "referenceMetadata": try artifact.referenceMetadata.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull(),
                ] as [String: Any]
            }
            let manifest: [String: Any] = [
                "schemaVersion": 1,
                "captureDeviceId": captureDeviceID.uuidString,
                "dog": [
                    "id": profile.id.uuidString,
                    "numberOrName": profile.numberOrName,
                    "expectedRevision": profile.revision,
                ],
                "dogProfileVersion": [
                    "id": profile.profileVersionID.uuidString,
                    "schemaVersion": profile.questionnaire.schemaVersion,
                    "validationState": "complete",
                    "questionnaire": profileJSON,
                    "contentSha256": profile.contentSha256,
                    "clientCreatedAtUtc": profile.updatedAtUTC,
                ],
                "recording": [
                    "source": recording.source,
                    "captureStatus": recording.status,
                    "startedAtUtc": recording.startedAtUTC,
                    "endedAtUtc": recording.endedAtUTC.map { $0 as Any } ?? NSNull(),
                    "timezone": recording.timezone,
                    "sessionLabel": recording.sessionLabel,
                    "videoRequested": recording.videoRequested,
                    "sensorHardwareId": NSNull(),
                    "appVersion": recording.appVersion ?? "unknown",
                    "protocolVersion": "1",
                    "questionnaireSchemaVersion": questionnaire.schemaVersion,
                    "questionnaireValidationState": "complete",
                    "sessionQuestionnaire": sessionJSON,
                    "captureErrorCode": captureErrorCode ?? NSNull(),
                    "captureErrorMessage": captureErrorMessage ?? NSNull(),
                ],
                "sync": sync,
                "artifacts": artifactPayloads,
            ]
            let body = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])
            if !alreadyComplete {
                let receipt: ServerProfileReceipt = try await json(
                    method: "PUT",
                    path: "/v1/recordings/\(recording.id.uuidString)",
                    body: body,
                    as: ServerProfileReceipt.self
                )
                try store.setServerRevision(dogID: profile.id, revision: receipt.dogRevision)
            } else {
                for payload in artifactPayloads {
                    _ = try await rawRequest(method: "POST", path: "/v1/recordings/\(recording.id.uuidString)/references",
                        body: try JSONSerialization.data(withJSONObject: payload), contentType: "application/json")
                }
            }
            for artifact in artifacts {
                let file = store.rootDirectory.appendingPathComponent(artifact.relativePath)
                let offset = try await uploadOffset(artifact.id)
                guard offset <= artifact.sizeBytes else { throw ServerSyncError.responseInvalid }
                try store.updateArtifactProgress(artifact.id, uploadedBytes: offset, state: "uploading")
                onProgress?()
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset))
                var current = offset
                while current < artifact.sizeBytes {
                    let count = Int(min(8 * 1_024 * 1_024, artifact.sizeBytes - current))
                    guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                        throw ServerSyncError.responseInvalid
                    }
                    let response = try await rawRequest(
                        method: "PATCH",
                        path: "/v1/artifacts/\(artifact.id.uuidString)/content",
                        body: chunk,
                        contentType: "application/offset+octet-stream",
                        headers: ["Upload-Offset": String(current)]
                    )
                    current = Int64(response.value(forHTTPHeaderField: "Upload-Offset") ?? "")
                        ?? current + Int64(chunk.count)
                    try store.updateArtifactProgress(artifact.id, uploadedBytes: current, state: "uploading")
                    onProgress?()
                }
                _ = try await rawRequest(
                    method: "POST",
                    path: "/v1/artifacts/\(artifact.id.uuidString)/complete",
                    body: Data("{}".utf8),
                    contentType: "application/json"
                )
                try store.updateArtifactProgress(artifact.id, uploadedBytes: artifact.sizeBytes, state: "available")
                onProgress?()
            }
            if !alreadyComplete {
                _ = try await rawRequest(
                    method: "POST",
                    path: "/v1/recordings/\(recording.id.uuidString)/complete",
                    body: Data("{}".utf8),
                    contentType: "application/json"
                )
            }
            let accepted: ServerRecordingDetail = try await json(method: "GET", path: "/v1/recordings/\(recording.id.uuidString)", body: Optional<Data>.none, as: ServerRecordingDetail.self)
            try store.acceptServerProfile(dogID: accepted.dogId, version: accepted.profileVersion)
            let canonical = try JSONDecoder().decode(SessionQuestionnaire.self, from: JSONEncoder().encode(accepted.sessionQuestionnaire))
            try store.saveSessionQuestionnaire(recordingID: accepted.id, questionnaire: canonical, revision: accepted.questionnaireRevision ?? 1)
            try store.updateRecordingSync(recording.id, state: "synced")
        } catch {
            let state: String
            if case ServerSyncError.animalIDConflict = error {
                state = "permanent_error"
            } else if case ServerSyncError.requestFailed(let status, _) = error,
               [400, 401, 403, 404, 409, 410, 413, 422].contains(status) {
                state = "permanent_error"
            } else if case WoonaStoreError.invalidData = error {
                state = "permanent_error"
            } else {
                state = "retryable_error"
            }
            try? store.updateRecordingSync(recording.id, state: state, error: error)
            throw error
        }
    }

    func download(artifactID: UUID, to target: URL, expectedSize: Int64, sha256: String) async throws {
        let part = target.appendingPathExtension("part")
        let attributes = try? FileManager.default.attributesOfItem(atPath: part.path)
        var offset = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if attributes != nil, offset == expectedSize {
            if try WoonaStore.sha256File(part) == sha256 {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: part, to: target)
                return
            }
        }
        if offset >= expectedSize {
            try? FileManager.default.removeItem(at: part)
            offset = 0
        }
        var request = try makeRequest(method: "GET", path: "/v1/artifacts/\(artifactID.uuidString)/content")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (temporary, response) = try await session.download(for: request)
        try validate(response: response, data: Data())
        let didResume = offset > 0 && (response as? HTTPURLResponse)?.statusCode == 206
        if !didResume {
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: temporary, to: part)
        } else {
            let input = try FileHandle(forReadingFrom: temporary)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: part)
            defer { try? output.close() }
            try output.seekToEnd()
            while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
        }
        let size = (try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value
        guard size == expectedSize, try WoonaStore.sha256File(part) == sha256 else {
            throw ServerSyncError.responseInvalid
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: part, to: target)
    }

    private func json<T: Decodable>(method: String, path: String, body: Data?, as type: T.Type) async throws -> T {
        var request = try makeRequest(method: method, path: path)
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(type, from: data)
    }

    private func uploadOffset(_ artifactID: UUID) async throws -> Int64 {
        let response = try await rawRequest(method: "HEAD", path: "/v1/artifacts/\(artifactID.uuidString)/content")
        guard let value = response.value(forHTTPHeaderField: "Upload-Offset"), let offset = Int64(value) else {
            throw ServerSyncError.responseInvalid
        }
        return offset
    }

    @discardableResult
    private func rawRequest(
        method: String,
        path: String,
        body: Data? = nil,
        contentType: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> HTTPURLResponse {
        var request = try makeRequest(method: method, path: path)
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        guard let response = response as? HTTPURLResponse else { throw ServerSyncError.responseInvalid }
        return response
    }

    private func makeRequest(method: String, path: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw ServerSyncError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountID { request.setValue(accountID, forHTTPHeaderField: "X-Woona-Account") }
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw ServerSyncError.responseInvalid }
        guard (200...299).contains(response.statusCode) else {
            throw ServerSyncError.responseError(status: response.statusCode, data: data)
        }
    }
}

private struct RecordingUploadStatus: Decodable {
    let ingestStatus: String
}
