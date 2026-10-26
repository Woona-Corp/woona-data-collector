import CryptoKit
import Foundation
import SQLite3

struct RecordingArchive: Sendable {
    struct File: Sendable {
        let url: URL
        let size: Int64
        let sha256: String
    }
    let files: [File]
    let manifest: Data
    let name: String

    func create(in directory: URL) throws -> URL {
        let manager = FileManager.default
        let staging = directory.appendingPathComponent(name, isDirectory: true)
        let archive = directory.appendingPathComponent(name + ".zip")
        guard !manager.fileExists(atPath: staging.path), !manager.fileExists(atPath: archive.path) else {
            throw WoonaStoreError.invalidData("Export destination already exists")
        }
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: staging) }
            for file in files {
                let target = staging.appendingPathComponent(file.url.lastPathComponent)
                try manager.copyItem(at: file.url, to: target)
                let handle = try FileHandle(forReadingFrom: target)
                defer { try? handle.close() }
                var hash = SHA256()
                var size: Int64 = 0
                while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
                    size += Int64(data.count)
                    hash.update(data: data)
                }
                guard size == file.size, hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                    throw WoonaStoreError.invalidData("Local artifact size or SHA-256 changed: \(file.url.lastPathComponent)")
                }
            }
            try manifest.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordinationError) { zipped in
                do { try manager.copyItem(at: zipped, to: archive) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            guard manager.fileExists(atPath: archive.path) else { throw WoonaStoreError.invalidData("The session archive was not created") }
            return archive
        } catch {
            try? manager.removeItem(at: archive)
            throw error
        }
    }
}

/// A verified immutable snapshot; file hashing/removal runs off the main thread.
struct LocalRecordingRemoval: Sendable {
    let directory: URL
    let files: [RecordingArchive.File]

    func removeFiles() throws -> Int64 {
        let manager = FileManager.default
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var existing: [(RecordingArchive.File, Date?)] = []
        for file in files {
            let resolved = file.url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root), resolved.path != directory.path else { throw WoonaStoreError.invalidData("local_copy_unsafe_path") }
            if manager.fileExists(atPath: file.url.path) {
                let attrs = try manager.attributesOfItem(atPath: file.url.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      (attrs[.size] as? NSNumber)?.int64Value == file.size,
                      try WoonaStore.sha256File(file.url) == file.sha256 else { throw WoonaStoreError.invalidData("local_copy_changed") }
                existing.append((file, attrs[.modificationDate] as? Date))
            }
        }
        var removedBytes: Int64 = 0
        for (file, modified) in existing {
            let attrs = try manager.attributesOfItem(atPath: file.url.path)
            guard file.url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root),
                  (attrs[.size] as? NSNumber)?.int64Value == file.size,
                  attrs[.modificationDate] as? Date == modified else { throw WoonaStoreError.invalidData("local_copy_changed") }
            try manager.removeItem(at: file.url)
            removedBytes += file.size
        }
        return removedBytes
    }
}

struct QuestionnaireValidation: Equatable {
    let errors: [String: String]
    var isValid: Bool { errors.isEmpty }
}

struct DogQuestionnaire: Codable, Equatable {
    var schemaVersion = 1
    var numberOrName = ""
    var shelterOrPlace = ""
    var breedStatus = ""
    var breedName: String?
    var resembles: String?
    var size = ""
    var ageStatus = ""
    var ageYears: Int?
    var ageMonths: Int?
    var ageSource = ""
    var sex = ""
    var sterilizationStatus = ""
    var weightStatus = ""
    var weightKg: Double?
    var bodyConditionStatus = ""
    var bodyConditionScore: Int?
    var muscleMass = ""
    var neckCircumferenceStatus = ""
    var neckCircumferenceCm: Double?
    var coatLength = ""
    var undercoat = ""
    var shavedAreasStatus = ""
    var shavedAreasDetails: String?
    var observedSigns: [String] = []
    var diagnosesStatus = ""
    var diagnosesDetails: String?
    var housing = ""
    var housingDetails: String?
    var walksStatus = ""
    var walksDescription: String?
    var cohabitants = ""
    var shelterPermission = ""
    var notesStatus = ""
    var notes: String?
    var animalId: String?
    var species: String?
    var savedAtLocal: String?
    var diseaseCategory: String?
    var diseaseCategoryDetails: String?
    var chronicLameness: String?
    var medications: String?
    var history: String?
    var specialistName: String?

    func validate() -> QuestionnaireValidation {
        if schemaVersion == 2 { return validateSheet() }
        var errors: [String: String] = [:]
        func required(_ key: String, _ value: String, max: Int) {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors[key] = "Required"
            } else if value.count > max {
                errors[key] = "Maximum \(max) characters"
            }
        }
        func detail(_ key: String, when enabled: Bool, value: String?, max: Int) {
            if enabled && (value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false || value!.count > max) {
                errors[key] = "Required"
            } else if !enabled && value != nil {
                errors[key] = "Must be empty"
            }
        }

        if schemaVersion != 1 { errors["schemaVersion"] = "Unsupported schema" }
        required("numberOrName", numberOrName, max: 100)
        required("shelterOrPlace", shelterOrPlace, max: 200)
        if !["purebred", "mixed", "unknown"].contains(breedStatus) { errors["breedStatus"] = "Required" }
        detail("breedName", when: ["purebred", "mixed"].contains(breedStatus), value: breedName, max: 100)
        detail("resembles", when: breedStatus == "mixed", value: resembles, max: 200)
        if !["small", "medium", "large", "giant", "unknown"].contains(size) { errors["size"] = "Required" }
        if !["known", "estimated", "unknown"].contains(ageStatus) { errors["ageStatus"] = "Required" }
        if ["known", "estimated"].contains(ageStatus) {
            if ageYears == nil && ageMonths == nil { errors["ageYears"] = "Enter years or months" }
            if !["documents", "shelter_report", "dental_estimate", "operator_estimate"].contains(ageSource) {
                errors["ageSource"] = "Required"
            }
        } else if ageStatus == "unknown" && (ageYears != nil || ageMonths != nil || ageSource != "unknown") {
            errors["ageStatus"] = "Unknown age cannot contain an estimate"
        }
        if let ageYears, !(0...40).contains(ageYears) { errors["ageYears"] = "Use 0–40" }
        if let ageMonths, !(0...11).contains(ageMonths) { errors["ageMonths"] = "Use 0–11" }
        if !["male", "female", "unknown"].contains(sex) { errors["sex"] = "Required" }
        if !["yes", "no", "unknown"].contains(sterilizationStatus) { errors["sterilizationStatus"] = "Required" }
        if !["measured", "estimated", "unknown"].contains(weightStatus) { errors["weightStatus"] = "Required" }
        if ["measured", "estimated"].contains(weightStatus) {
            if weightKg == nil || weightKg! <= 0 || weightKg! > 150 { errors["weightKg"] = "Use >0 and ≤150 kg" }
        } else if weightKg != nil { errors["weightKg"] = "Must be empty" }
        if !["assessed", "unable"].contains(bodyConditionStatus) { errors["bodyConditionStatus"] = "Required" }
        if bodyConditionStatus == "assessed" && (bodyConditionScore == nil || !(1...9).contains(bodyConditionScore!)) {
            errors["bodyConditionScore"] = "Use 1–9"
        } else if bodyConditionStatus == "unable" && bodyConditionScore != nil { errors["bodyConditionScore"] = "Must be empty" }
        if !["normal", "mild_loss", "moderate_loss", "severe_loss", "unable"].contains(muscleMass) { errors["muscleMass"] = "Required" }
        if !["measured", "not_measured"].contains(neckCircumferenceStatus) { errors["neckCircumferenceStatus"] = "Required" }
        if neckCircumferenceStatus == "measured" {
            if neckCircumferenceCm == nil || neckCircumferenceCm! <= 0 || neckCircumferenceCm! > 150 { errors["neckCircumferenceCm"] = "Use >0 and ≤150 cm" }
        } else if neckCircumferenceCm != nil { errors["neckCircumferenceCm"] = "Must be empty" }
        if !["short", "medium", "long", "unknown"].contains(coatLength) { errors["coatLength"] = "Required" }
        if !["none", "moderate", "dense", "unknown"].contains(undercoat) { errors["undercoat"] = "Required" }
        if !["none", "present", "unknown"].contains(shavedAreasStatus) { errors["shavedAreasStatus"] = "Required" }
        detail("shavedAreasDetails", when: shavedAreasStatus == "present", value: shavedAreasDetails, max: 500)
        let signs = Set(observedSigns)
        if observedSigns.isEmpty || signs.count != observedSigns.count || !signs.isSubset(of: Self.observedSignValues) {
            errors["observedSigns"] = "Invalid or duplicate sign"
        } else if !signs.isDisjoint(with: ["none", "unknown"]) && signs.count > 1 {
            errors["observedSigns"] = "None/unknown cannot be combined"
        }
        if !["yes", "no", "unknown"].contains(diagnosesStatus) { errors["diagnosesStatus"] = "Required" }
        detail("diagnosesDetails", when: diagnosesStatus == "yes", value: diagnosesDetails, max: 2_000)
        if !["enclosure", "room", "home", "free_range", "other", "unknown"].contains(housing) { errors["housing"] = "Required" }
        detail("housingDetails", when: housing == "other", value: housingDetails, max: 500)
        if !["known", "none", "unknown"].contains(walksStatus) { errors["walksStatus"] = "Required" }
        detail("walksDescription", when: walksStatus == "known", value: walksDescription, max: 500)
        if !["alone", "other_animals", "people_only", "unknown"].contains(cohabitants) { errors["cohabitants"] = "Required" }
        if !["yes", "no", "not_required", "unknown"].contains(shelterPermission) { errors["shelterPermission"] = "Required" }
        if !["none", "provided"].contains(notesStatus) { errors["notesStatus"] = "Required" }
        detail("notes", when: notesStatus == "provided", value: notes, max: 2_000)
        return QuestionnaireValidation(errors: errors)
    }

    mutating func normalizeConditionals() {
        if schemaVersion == 2 { return }
        if breedStatus != "mixed" { resembles = nil }
        if !["purebred", "mixed"].contains(breedStatus) { breedName = nil }
        if ageStatus == "unknown" { ageYears = nil; ageMonths = nil; ageSource = "unknown" }
        if weightStatus == "unknown" { weightKg = nil }
        if bodyConditionStatus == "unable" { bodyConditionScore = nil }
        if neckCircumferenceStatus == "not_measured" { neckCircumferenceCm = nil }
        if shavedAreasStatus != "present" { shavedAreasDetails = nil }
        if diagnosesStatus != "yes" { diagnosesDetails = nil }
        if housing != "other" { housingDetails = nil }
        if walksStatus != "known" { walksDescription = nil }
        if notesStatus != "provided" { notes = nil }
    }

    static let observedSignValues: Set<String> = [
        "none", "unknown", "labored_breathing", "fainting", "seizures",
        "cannot_urinate", "limb_weakness", "jaundice", "vomiting_or_no_appetite",
        "stool_changes", "cough", "pain_or_lameness", "thirst_changes", "distress",
    ]
}

struct SessionQuestionnaire: Codable, Equatable {
    var schemaVersion = 1
    var sessionLabel = ""
    var operatorName = ""
    var activityGroup = ""
    var activityType = ""
    var activityDetails: String?
    var location = ""
    var surface = ""
    var surfaceDetails: String?
    var airTemperatureStatus = ""
    var airTemperatureC: Double?
    var sensorPosition = ""
    var sensorPositionDetails: String?
    var collarTightness = ""
    var preMeasurementState = ""
    var preMeasurementStateDetails: String?
    var pulseStatus = ""
    var pulseBpm: Int?
    var respirationStatus = ""
    var respirationPerMinute: Int?
    var bodyTemperatureStatus = ""
    var bodyTemperatureC: Double?
    var measurementAtUtc: String?
    var videoRequested = true
    var animalId: String?
    var savedAtLocal: String?
    var sessionDate: String?
    var startTime: String?
    var endTime: String?
    var durationMinutes: Double?
    var plannedActivities: [String]?
    var surfaces: [String]?
    var lastMedicationAt: String?
    var notes: String?
    var specialistName: String?
    var sessionKind: String?
    var heartQuestionnaire: HeartQuestionnaire?

    func validate() -> QuestionnaireValidation {
        if schemaVersion == 2 { return validateSheet() }
        var errors: [String: String] = [:]
        func required(_ key: String, _ value: String, max: Int) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { errors[key] = "Required" }
            else if value.count > max { errors[key] = "Maximum \(max) characters" }
        }
        func detail(_ key: String, when enabled: Bool, value: String?, max: Int) {
            if enabled && (value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false || value!.count > max) {
                errors[key] = "Required"
            } else if !enabled && value != nil { errors[key] = "Must be empty" }
        }
        func measurement(_ key: String, status: String, value: Double?, range: ClosedRange<Double>) {
            if !["measured", "not_measured"].contains(status) { errors["\(key)Status"] = "Required" }
            if status == "measured" && (value == nil || !range.contains(value!)) { errors[key] = "Out of range" }
            if status == "not_measured" && value != nil { errors[key] = "Must be empty" }
        }

        if schemaVersion != 1 { errors["schemaVersion"] = "Unsupported schema" }
        required("sessionLabel", sessionLabel, max: 100)
        required("operatorName", operatorName, max: 150)
        if let activities = Self.activityTypes[activityGroup] {
            if !activities.contains(activityType) { errors["activityType"] = "Choose an activity" }
        } else { errors["activityGroup"] = "Required" }
        detail("activityDetails", when: ["mixed", "other"].contains(activityType), value: activityDetails, max: 1_000)
        if let surfaces = Self.surfaces[location] {
            if !surfaces.contains(surface) { errors["surface"] = "Choose a surface" }
        } else { errors["location"] = "Required" }
        detail("surfaceDetails", when: surface == "other", value: surfaceDetails, max: 300)
        measurement("airTemperature", status: airTemperatureStatus, value: airTemperatureC, range: -60...70)
        if !["dorsal_neck", "left_neck", "right_neck", "chest", "back", "other"].contains(sensorPosition) { errors["sensorPosition"] = "Required" }
        detail("sensorPositionDetails", when: sensorPosition == "other", value: sensorPositionDetails, max: 300)
        if !["loose", "snug", "tight"].contains(collarTightness) { errors["collarTightness"] = "Required" }
        if !["rest", "walk", "run", "play", "stress", "other", "unknown"].contains(preMeasurementState) { errors["preMeasurementState"] = "Required" }
        detail("preMeasurementStateDetails", when: preMeasurementState == "other", value: preMeasurementStateDetails, max: 500)
        measurement("pulse", status: pulseStatus, value: pulseBpm.map(Double.init), range: 20...300)
        measurement("respiration", status: respirationStatus, value: respirationPerMinute.map(Double.init), range: 1...200)
        measurement("bodyTemperature", status: bodyTemperatureStatus, value: bodyTemperatureC, range: 30...45)
        let hasMeasurements = [pulseStatus, respirationStatus, bodyTemperatureStatus].contains("measured")
        if hasMeasurements && (measurementAtUtc == nil || ISO8601DateFormatter().date(from: measurementAtUtc!) == nil) {
            errors["measurementAtUtc"] = "Enter a valid measurement time"
        } else if !hasMeasurements && measurementAtUtc != nil { errors["measurementAtUtc"] = "Must be empty" }
        return QuestionnaireValidation(errors: errors)
    }

    mutating func normalizeConditionals() {
        if schemaVersion == 2 { return }
        if !["mixed", "other"].contains(activityType) { activityDetails = nil }
        if surface != "other" { surfaceDetails = nil }
        if airTemperatureStatus == "not_measured" { airTemperatureC = nil }
        if sensorPosition != "other" { sensorPositionDetails = nil }
        if preMeasurementState != "other" { preMeasurementStateDetails = nil }
        if pulseStatus == "not_measured" { pulseBpm = nil }
        if respirationStatus == "not_measured" { respirationPerMinute = nil }
        if bodyTemperatureStatus == "not_measured" { bodyTemperatureC = nil }
        if ![pulseStatus, respirationStatus, bodyTemperatureStatus].contains("measured") { measurementAtUtc = nil }
    }

    static let activityTypes: [String: Set<String>] = [
        "locomotion": ["walk", "trot", "gallop", "run", "stairs_up", "stairs_down", "jump", "mixed"],
        "stationary": ["stand", "sit", "lie", "rest", "sleep"],
        "daily_living": ["play", "eat", "drink", "scratch", "groom", "other"],
        "other": ["other"],
    ]
    static let surfaces: [String: Set<String>] = [
        "indoors": ["tile", "concrete", "wood", "laminate", "carpet", "bed", "kennel_mat", "other"],
        "outdoors": ["asphalt", "concrete", "grass", "soil", "gravel", "snow", "other"],
    ]
}

extension DogQuestionnaire {
    func validateSheet() -> QuestionnaireValidation {
        var errors: [String: String] = [:]
        if (animalId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (animalId ?? "").count > 100 { errors["animalId"] = "Укажите ID животного (до 100 символов)" }
        if numberOrName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || numberOrName.count > 100 { errors["numberOrName"] = "Укажите кличку (до 100 символов)" }
        let textFields: [(String, String?, Int)] = [
            ("shelterOrPlace", shelterOrPlace, 200), ("breedName", breedName, 100), ("resembles", resembles, 200),
            ("shavedAreasDetails", shavedAreasDetails, 500), ("diagnosesDetails", diagnosesDetails, 2000),
            ("housingDetails", housingDetails, 500), ("walksDescription", walksDescription, 500),
            ("notes", notes, 2000), ("medications", medications, 2000), ("history", history, 2000),
            ("specialistName", specialistName, 2000), ("diseaseCategory", diseaseCategory, 2000),
            ("diseaseCategoryDetails", diseaseCategoryDetails, 2000),
        ]
        for (key, value, limit) in textFields {
            if let value, value.count > limit { errors[key] = "Максимум \(limit) символов" }
        }
        if let ageYears, !(0...40).contains(ageYears) { errors["ageYears"] = "Укажите 0–40 лет" }
        if let ageMonths, !(0...11).contains(ageMonths) { errors["ageMonths"] = "Укажите 0–11 месяцев" }
        if let weightKg, !weightKg.isFinite || weightKg <= 0 || weightKg > 150 { errors["weightKg"] = "Вес должен быть >0 и ≤150 кг" }
        if let bodyConditionScore, !(1...9).contains(bodyConditionScore) { errors["bodyConditionScore"] = "BCS: 1–9" }
        if let neckCircumferenceCm, !neckCircumferenceCm.isFinite || neckCircumferenceCm <= 0 || neckCircumferenceCm > 150 { errors["neckCircumferenceCm"] = "Обхват должен быть >0 и ≤150 см; оставьте пустым, если не измерен" }
        return QuestionnaireValidation(errors: errors)
    }
}

extension SessionQuestionnaire {
    func validateSheet() -> QuestionnaireValidation {
        var errors: [String: String] = [:]
        if sessionLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sessionLabel.count > 100 { errors["sessionLabel"] = "Укажите номер сессии (до 100 символов)" }
        let textFields: [(String, String?, Int)] = [
            ("operatorName", operatorName, 150), ("activityDetails", activityDetails, 1000),
            ("surfaceDetails", surfaceDetails, 300), ("sensorPositionDetails", sensorPositionDetails, 300),
            ("preMeasurementStateDetails", preMeasurementStateDetails, 500), ("notes", notes, 2000),
            ("lastMedicationAt", lastMedicationAt, 2000), ("specialistName", specialistName, 2000),
        ]
        for (key, value, limit) in textFields {
            if let value, value.count > limit { errors[key] = "Максимум \(limit) символов" }
        }
        let activities = plannedActivities ?? []
        if sessionKind != "heart" && (activities.isEmpty || activities.contains(where: { $0.isEmpty }) || Set(activities).count != activities.count) { errors["plannedActivities"] = "Выберите формат записи" }
        if let sessionKind, !["heart", "activity"].contains(sessionKind) { errors["sessionKind"] = "Выберите вид сессии" }
        if let heartQuestionnaire { errors.merge(heartQuestionnaire.validate().errors) { _, new in new } }
        let selectedSurfaces = surfaces ?? []
        if selectedSurfaces.contains(where: { $0.isEmpty }) || Set(selectedSurfaces).count != selectedSurfaces.count { errors["surfaces"] = "Проверьте поверхности" }
        if let airTemperatureC, !airTemperatureC.isFinite || !(-60...70).contains(airTemperatureC) { errors["airTemperatureC"] = "Температура: −60…70 °C" }
        if let durationMinutes, !durationMinutes.isFinite || durationMinutes < 0 { errors["durationMinutes"] = "Продолжительность должна быть ≥0" }
        for (key, value, format) in [("sessionDate", sessionDate, "yyyy-MM-dd"), ("startTime", startTime, "HH:mm"), ("endTime", endTime, "HH:mm")] {
            if let value, !value.isEmpty {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = format
                formatter.isLenient = false
                if formatter.date(from: value) == nil { errors[key] = "Формат: \(format)" }
            }
        }
        return QuestionnaireValidation(errors: errors)
    }
}

struct DogProfile: Identifiable, Equatable {
    let id: UUID
    let profileVersionID: UUID
    let revision: Int
    let contentSha256: String
    let questionnaire: DogQuestionnaire
    let createdAtUTC: String
    let updatedAtUTC: String
    var accountID: String? = nil
    var numberOrName: String { questionnaire.numberOrName }
}

struct WoonaRecording: Identifiable, Equatable {
    let id: UUID
    let dogID: UUID
    let profileVersionID: UUID
    let source: String
    let status: String
    let sessionLabel: String
    let videoRequested: Bool
    let startedAtUTC: String
    let endedAtUTC: String?
    let timezone: String
    let questionnaire: SessionQuestionnaire?
    let relativeDirectory: String
    let serverSyncState: String
    var appVersion: String? = nil
    var questionnaireRevision = 1
    var questionnaireDirty = false
    var captureErrorCode: String? = nil
    var captureErrorMessage: String? = nil
}

struct LocalArtifact: Identifiable, Equatable {
    let id: UUID
    let recordingID: UUID
    let type: String
    let fileName: String
    let relativePath: String
    let mimeType: String
    let sizeBytes: Int64
    let sha256: String
    let uploadedBytes: Int64
    var referenceMetadata: ReferenceMetadata? = nil
    var uploadState = "pending"
}

enum WoonaStoreError: LocalizedError {
    case sqlite(String)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message), .invalidData(let message): message
        }
    }
}

final class WoonaStore {
    private var database: OpaquePointer?
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) throws {
        let base = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Woona", isDirectory: true)
        self.rootDirectory = base
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard sqlite3_open(base.appendingPathComponent("woona.sqlite").path, &database) == SQLITE_OK else {
            throw WoonaStoreError.sqlite("Unable to open woona.sqlite")
        }
        try execute("PRAGMA foreign_keys=ON")
        sqlite3_busy_timeout(database, 5_000)
        try migrate()
    }

    deinit { sqlite3_close(database) }

    func localInventory() throws -> (profiles: Int, recordings: Int) {
        let statement = try prepare("SELECT (SELECT COUNT(*) FROM dogs), (SELECT COUNT(*) FROM recordings)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw WoonaStoreError.sqlite("Unable to count local data") }
        return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)))
    }

    func syncOverview() throws -> (pending: Int, uploading: Int, synced: Int, failed: Int, lastError: String?) {
        let statement = try prepare("""
            SELECT
              SUM(CASE WHEN server_sync_state='pending' THEN 1 ELSE 0 END),
              SUM(CASE WHEN server_sync_state='uploading' THEN 1 ELSE 0 END),
              SUM(CASE WHEN server_sync_state IN ('synced','remote') THEN 1 ELSE 0 END),
              SUM(CASE WHEN server_sync_state IN ('retryable_error','permanent_error') THEN 1 ELSE 0 END),
              (SELECT last_error_message FROM server_sync_state WHERE state IN ('retryable_error','permanent_error') ORDER BY updated_at_utc DESC LIMIT 1)
            FROM recordings
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw WoonaStoreError.sqlite("Unable to load upload queue") }
        return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)), Int(sqlite3_column_int64(statement, 2)), Int(sqlite3_column_int64(statement, 3)), columnOptionalText(statement, 4))
    }

    func profiles() throws -> [DogProfile] {
        let statement = try prepare(
            """
            SELECT d.id,d.current_profile_version_id,d.revision,v.content_sha256,
                   v.questionnaire_json,d.created_at_utc,d.updated_at_utc,d.account_id
            FROM dogs d JOIN dog_profile_versions v ON v.id=d.current_profile_version_id
            WHERE d.archived_at_utc IS NULL ORDER BY d.updated_at_utc DESC
            """
        )
        defer { sqlite3_finalize(statement) }
        var result: [DogProfile] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let questionnaire = try JSONDecoder().decode(
                DogQuestionnaire.self,
                from: Data(columnText(statement, 4).utf8)
            )
            guard let id = UUID(uuidString: columnText(statement, 0)),
                  let versionID = UUID(uuidString: columnText(statement, 1)) else {
                throw WoonaStoreError.invalidData("Invalid profile UUID")
            }
            result.append(
                DogProfile(
                    id: id,
                    profileVersionID: versionID,
                    revision: Int(sqlite3_column_int64(statement, 2)),
                    contentSha256: columnText(statement, 3),
                    questionnaire: questionnaire,
                    createdAtUTC: columnText(statement, 5),
                    updatedAtUTC: columnText(statement, 6),
                    accountID: columnOptionalText(statement, 7)
                )
            )
        }
        return result
    }

    func profile(dogID: UUID, versionID: UUID) throws -> DogProfile? {
        let statement = try prepare(
            """
            SELECT d.id,v.id,d.revision,v.content_sha256,v.questionnaire_json,d.created_at_utc,d.updated_at_utc,d.account_id
            FROM dogs d JOIN dog_profile_versions v ON v.dog_id=d.id
            WHERE d.id=? AND v.id=? LIMIT 1
            """,
            [.text(dogID.uuidString), .text(versionID.uuidString)]
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return DogProfile(
            id: dogID,
            profileVersionID: versionID,
            revision: Int(sqlite3_column_int64(statement, 2)),
            contentSha256: columnText(statement, 3),
            questionnaire: try JSONDecoder().decode(DogQuestionnaire.self, from: Data(columnText(statement, 4).utf8)),
            createdAtUTC: columnText(statement, 5),
            updatedAtUTC: columnText(statement, 6),
            accountID: columnOptionalText(statement, 7)
        )
    }

    @discardableResult
    func saveProfile(_ questionnaire: DogQuestionnaire, replacing profile: DogProfile? = nil, accountID: String? = nil) throws -> DogProfile {
        let validation = questionnaire.validate()
        guard validation.isValid else { throw WoonaStoreError.invalidData("Dog questionnaire is incomplete") }
        if let profile {
            var previous = profile.questionnaire
            var proposed = questionnaire
            previous.savedAtLocal = nil
            proposed.savedAtLocal = nil
            if previous == proposed { return profile }
        }
        let dogID = profile?.id ?? UUID()
        let versionID = UUID()
        let now = Self.iso8601(Date())
        let questionnaireData = try Self.dogQuestionnaireData(questionnaire)
        let json = String(data: questionnaireData, encoding: .utf8)!
        try transaction {
            if let profile {
                try execute(
                    "UPDATE dog_profile_versions SET superseded_at_utc=? WHERE dog_id=? AND superseded_at_utc IS NULL",
                    [.text(now), .text(profile.id.uuidString)]
                )
                try execute(
                    "UPDATE dogs SET current_profile_version_id=?,number_or_name=?,updated_at_utc=? WHERE id=?",
                    [.text(versionID.uuidString), .text(questionnaire.numberOrName), .text(now), .text(profile.id.uuidString)]
                )
            } else {
                try execute(
                    "INSERT INTO dogs(id,current_profile_version_id,number_or_name,revision,created_at_utc,updated_at_utc) VALUES(?,?,?,0,?,?)",
                    [.text(dogID.uuidString), .text(versionID.uuidString), .text(questionnaire.numberOrName), .text(now), .text(now)]
                )
            }
            try execute(
                "INSERT INTO dog_profile_versions(id,dog_id,schema_version,validation_state,questionnaire_json,content_sha256,client_created_at_utc) VALUES(?,?,?,'complete',?,?,?)",
                [.text(versionID.uuidString), .text(dogID.uuidString), .integer(Int64(questionnaire.schemaVersion)), .text(json), .text(Self.sha256(questionnaireData)), .text(now)]
            )
            if profile == nil { try execute("UPDATE dogs SET account_id=? WHERE id=?", [accountID.map(SQLiteValue.text) ?? .null, .text(dogID.uuidString)]) }
        }
        return try profiles().first { $0.id == dogID }!
    }

    func linkDog(dogID: UUID, accountID: String) throws {
        guard let dog = try profiles().first(where: { $0.id == dogID }), dog.accountID == nil || dog.accountID == accountID else {
            throw WoonaStoreError.invalidData("Dog already belongs to another account")
        }
        try execute("UPDATE dogs SET account_id=? WHERE id=?", [.text(accountID), .text(dogID.uuidString)])
    }

    func setServerRevision(dogID: UUID, revision: Int) throws {
        try execute("UPDATE dogs SET revision=MAX(revision,?) WHERE id=?", [.integer(Int64(revision)), .text(dogID.uuidString)])
    }

    @discardableResult
    func upsertRemoteProfile(
        dogID: UUID,
        profileVersionID: UUID,
        revision: Int,
        questionnaire: DogQuestionnaire,
        contentSha256: String,
        updatedAtUTC: String,
        accountID: String? = nil
    ) throws -> DogProfile {
        let json = String(data: try Self.dogQuestionnaireData(questionnaire), encoding: .utf8)!
        let existing = try profiles().first { $0.id == dogID }
        guard existing?.accountID == nil || existing?.accountID == accountID else {
            throw WoonaStoreError.invalidData("Remote dog account conflicts with local ownership")
        }
        let preserveLocal = existing.map {
            $0.profileVersionID != profileVersionID && ($0.revision == 0 || $0.revision >= revision)
        } ?? false
        if let version = try existingProfileVersion(id: profileVersionID),
           version.dogID != dogID || version.sha256 != contentSha256 {
            throw WoonaStoreError.invalidData("Remote profile version conflicts with local metadata")
        }
        try transaction {
            if let existing, existing.profileVersionID != profileVersionID, !preserveLocal {
                try execute(
                    "UPDATE dog_profile_versions SET superseded_at_utc=? WHERE dog_id=? AND superseded_at_utc IS NULL",
                    [.text(updatedAtUTC), .text(dogID.uuidString)]
                )
            }
            if preserveLocal {
                try execute("UPDATE dogs SET revision=? WHERE id=?", [.integer(Int64(revision)), .text(dogID.uuidString)])
            } else {
                try execute(
                    """
                    INSERT INTO dogs(id,current_profile_version_id,number_or_name,revision,created_at_utc,updated_at_utc)
                    VALUES(?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      current_profile_version_id=excluded.current_profile_version_id,
                      number_or_name=excluded.number_or_name,revision=excluded.revision,
                      updated_at_utc=excluded.updated_at_utc
                    """,
                    [
                        .text(dogID.uuidString), .text(profileVersionID.uuidString),
                        .text(questionnaire.numberOrName), .integer(Int64(revision)),
                        .text(existing?.createdAtUTC ?? updatedAtUTC), .text(updatedAtUTC),
                    ]
                )
            }
            try execute(
                """
                INSERT OR IGNORE INTO dog_profile_versions(
                  id,dog_id,schema_version,validation_state,questionnaire_json,
                  content_sha256,client_created_at_utc,superseded_at_utc
                ) VALUES(?,?,?,'complete',?,?,?,?)
                """,
                [
                    .text(profileVersionID.uuidString), .text(dogID.uuidString), .integer(Int64(questionnaire.schemaVersion)), .text(json),
                    .text(contentSha256), .text(updatedAtUTC), preserveLocal ? .text(updatedAtUTC) : .null,
                ]
            )
            try execute("UPDATE dogs SET account_id=? WHERE id=?", [accountID.map(SQLiteValue.text) ?? .null, .text(dogID.uuidString)])
        }
        return try profiles().first { $0.id == dogID }!
    }

    func restoreRemoteProfileVersion(dogID: UUID, version: ServerProfileVersion) throws {
        guard try profiles().contains(where: { $0.id == dogID }) else {
            throw WoonaStoreError.invalidData("Remote profile version references an unknown dog")
        }
        if let existing = try existingProfileVersion(id: version.id) {
            guard existing.dogID == dogID, existing.sha256 == version.contentSha256 else {
                throw WoonaStoreError.invalidData("Remote profile version conflicts with local metadata")
            }
            return
        }
        let questionnaire = String(data: try Self.dogQuestionnaireData(version.questionnaire), encoding: .utf8)!
        try execute(
            """
            INSERT INTO dog_profile_versions(
              id,dog_id,schema_version,validation_state,questionnaire_json,
              content_sha256,client_created_at_utc,superseded_at_utc
            ) VALUES(?,?,?,?,?,?,?,?)
            """,
            [
                .text(version.id.uuidString), .text(dogID.uuidString), .integer(Int64(version.schemaVersion)),
                .text(version.validationState), .text(questionnaire), .text(version.contentSha256),
                .text(version.clientCreatedAtUtc), version.supersededAtUtc.map(SQLiteValue.text) ?? .null,
            ]
        )
    }

    @discardableResult
    func createRecording(profile: DogProfile, source: String, questionnaire: SessionQuestionnaire) throws -> WoonaRecording {
        var questionnaire = questionnaire
        if questionnaire.schemaVersion == 2 { questionnaire.animalId = profile.questionnaire.animalId }
        guard questionnaire.validate().isValid else { throw WoonaStoreError.invalidData("Session questionnaire is incomplete") }
        let id = UUID()
        let now = Date()
        let started = Self.iso8601(now)
        if questionnaire.schemaVersion == 2 && source == "live" {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            questionnaire.sessionDate = formatter.string(from: now)
            formatter.dateFormat = "HH:mm"
            questionnaire.startTime = formatter.string(from: now)
        }
        let date = Self.dayFormatter.string(from: now)
        let relative = "recordings/\(profile.id.uuidString)/\(date)/\(id.uuidString)"
        try FileManager.default.createDirectory(
            at: rootDirectory.appendingPathComponent(relative, isDirectory: true),
            withIntermediateDirectories: true
        )
        let json = String(data: try Self.sessionQuestionnaireData(questionnaire), encoding: .utf8)!
        try transaction {
            try execute(
                """
                INSERT INTO recordings(
                  id,dog_id,dog_profile_version_id,source,status,session_label,
                  video_requested,started_at_utc,timezone,questionnaire_json,
                  relative_directory,server_sync_state
                ) VALUES(?,?,?,?,'preparing',?,?,?,?,?,?,'pending')
                """,
                [
                    .text(id.uuidString), .text(profile.id.uuidString), .text(profile.profileVersionID.uuidString),
                    .text(source), .text(questionnaire.sessionLabel), .integer(questionnaire.videoRequested ? 1 : 0),
                    .text(started), .text(TimeZone.current.identifier), .text(json), .text(relative),
                ]
            )
            try execute("UPDATE recordings SET app_version=? WHERE id=?",
                        [.text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"), .text(id.uuidString)])
        }
        return try recording(id: id)!
    }

    @discardableResult
    func restoreRemoteRecording(_ remote: ServerRecordingDetail) throws -> Bool {
        guard try profiles().contains(where: { $0.id == remote.dogId }) else {
            throw WoonaStoreError.invalidData("Remote recording references an unknown dog")
        }
        guard try profiles().first(where: { $0.id == remote.dogId })?.accountID == remote.accountId else { throw WoonaStoreError.invalidData("Recording account conflicts with dog") }
        let existingRecording = try recording(id: remote.id)
        if let existingRecording,
           remote.ingestStatus != "complete" && (existingRecording.dogID != remote.dogId || existingRecording.profileVersionID != remote.profileVersion.id) {
            throw WoonaStoreError.invalidData("Remote recording conflicts with local metadata")
        }
        let didExist = existingRecording != nil
        let restoredSyncState = remote.ingestStatus == "complete" && existingRecording?.questionnaireDirty != true
            ? "synced" : (existingRecording?.serverSyncState ?? "remote")
        let relative = "recordings/\(remote.dogId.uuidString)/\(remote.startedAtUtc.prefix(10))/\(remote.id.uuidString)"
        try FileManager.default.createDirectory(
            at: rootDirectory.appendingPathComponent(relative, isDirectory: true),
            withIntermediateDirectories: true
        )
        let profileJSON = String(data: try Self.dogQuestionnaireData(remote.profileVersion.questionnaire), encoding: .utf8)!
        let sessionJSON = String(data: try Self.encoder.encode(remote.sessionQuestionnaire), encoding: .utf8)!
        var restoredSync = remote.sync
        if case .object(var fields) = restoredSync {
            if let code = remote.captureErrorCode { fields["captureErrorCode"] = .string(code) }
            if let message = remote.captureErrorMessage { fields["captureErrorMessage"] = .string(message) }
            restoredSync = .object(fields)
        }
        let syncJSON = String(data: try Self.encoder.encode(restoredSync), encoding: .utf8)!
        let now = Self.iso8601(Date())
        try transaction {
            if let version = try existingProfileVersion(id: remote.profileVersion.id),
               version.dogID != remote.dogId || version.sha256 != remote.profileVersion.contentSha256 {
                throw WoonaStoreError.invalidData("Remote profile version conflicts with local metadata")
            }
            try execute(
                """
                INSERT OR IGNORE INTO dog_profile_versions(
                  id,dog_id,schema_version,validation_state,questionnaire_json,
                  content_sha256,client_created_at_utc,superseded_at_utc
                ) VALUES(?,?,?,?,?,?,?,?)
                """,
                [
                    .text(remote.profileVersion.id.uuidString), .text(remote.dogId.uuidString),
                    .integer(Int64(remote.profileVersion.schemaVersion)), .text(remote.profileVersion.validationState), .text(profileJSON),
                    .text(remote.profileVersion.contentSha256), .text(remote.profileVersion.clientCreatedAtUtc),
                    .text(remote.startedAtUtc),
                ]
            )
            try execute(
                """
                INSERT OR IGNORE INTO recordings(
                  id,dog_id,dog_profile_version_id,source,status,session_label,
                  video_requested,started_at_utc,ended_at_utc,timezone,
                  questionnaire_json,relative_directory,server_sync_state
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,'synced')
                """,
                [
                    .text(remote.id.uuidString), .text(remote.dogId.uuidString),
                    .text(remote.profileVersion.id.uuidString), .text(remote.source),
                    .text(remote.captureStatus), .text(remote.sessionLabel),
                    .integer(remote.videoRequested ? 1 : 0), .text(remote.startedAtUtc),
                    remote.endedAtUtc.map(SQLiteValue.text) ?? .null, .text(remote.timezone),
                    .text(sessionJSON), .text(relative),
                ]
            )
            try execute(
                "INSERT OR IGNORE INTO recording_sync(recording_id,sync_json,updated_at_utc) VALUES(?,?,?)",
                [.text(remote.id.uuidString), .text(syncJSON), .text(now)]
            )
            if existingRecording != nil && existingRecording?.questionnaireDirty != true {
                try execute("UPDATE recordings SET dog_id=?,dog_profile_version_id=?,questionnaire_json=?,session_label=? WHERE id=?",
                            [.text(remote.dogId.uuidString),.text(remote.profileVersion.id.uuidString),.text(sessionJSON),.text(remote.sessionLabel),.text(remote.id.uuidString)])
                if remote.ingestStatus == "complete" || existingRecording?.serverSyncState == "remote" {
                    try execute("UPDATE recording_sync SET sync_json=?,updated_at_utc=? WHERE recording_id=?",
                                [.text(syncJSON),.text(now),.text(remote.id.uuidString)])
                }
            }
            if existingRecording?.questionnaireDirty != true { try execute("UPDATE recordings SET questionnaire_revision=? WHERE id=?", [.integer(Int64(remote.questionnaireRevision ?? 1)), .text(remote.id.uuidString)]) }
            if let appVersion = remote.appVersion {
                try execute("UPDATE recordings SET app_version=? WHERE id=?", [.text(appVersion), .text(remote.id.uuidString)])
            }
            for artifact in remote.artifacts {
                if let existing = try existingArtifact(id: artifact.id),
                   existing.recordingID != remote.id || existing.sha256 != artifact.sha256 {
                    throw WoonaStoreError.invalidData("Remote artifact conflicts with local metadata")
                }
                let matching = try artifacts(recordingID: remote.id).filter {
                    $0.id == artifact.id || $0.fileName == artifact.fileName
                }
                guard matching.allSatisfy({ $0.sha256 == artifact.sha256 && $0.sizeBytes == artifact.sizeBytes &&
                                            $0.type == artifact.type && $0.fileName == artifact.fileName }) else {
                    throw WoonaStoreError.invalidData("Remote artifact conflicts with local file metadata")
                }
                let originalPath = (existingRecording?.relativeDirectory ?? relative) + "/" + artifact.fileName
                if let local = matching.first(where: { $0.relativePath == originalPath }) ?? matching.first,
                   local.id != artifact.id || matching.count > 1 {
                    guard remote.ingestStatus == "complete" else {
                        throw WoonaStoreError.invalidData("Artifact identity can only be reconciled with a completed server record")
                    }
                    // Old restores could leave a remote placeholder beside the same phone file.
                    for other in matching where other.id != local.id {
                        try execute("DELETE FROM artifacts WHERE id=? AND recording_id=?", [.text(other.id.uuidString), .text(remote.id.uuidString)])
                    }
                    try execute("UPDATE artifacts SET id=? WHERE id=? AND recording_id=?",
                                [.text(artifact.id.uuidString), .text(local.id.uuidString), .text(remote.id.uuidString)])
                }
                let relativePath = "\(relative)/\(artifact.fileName)"
                try execute(
                    """
                    INSERT OR IGNORE INTO artifacts(
                      id,recording_id,type,file_name,relative_path,mime_type,
                      size_bytes,sha256,upload_state,uploaded_bytes,created_at_utc,reference_metadata_json
                    ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    [
                        .text(artifact.id.uuidString), .text(remote.id.uuidString), .text(artifact.type),
                        .text(artifact.fileName), .text(relativePath), .text(artifact.mimeType),
                        .integer(artifact.sizeBytes), .text(artifact.sha256), .text(artifact.storageStatus),
                        .integer(artifact.storageStatus == "available" ? artifact.sizeBytes : 0),
                        .text(remote.startedAtUtc),
                        try artifact.referenceMetadata.map { .text(String(decoding: try Self.encoder.encode($0), as: UTF8.self)) } ?? .null,
                    ]
                )
                try updateArtifactProgress(artifact.id,
                                           uploadedBytes: artifact.storageStatus == "available" ? artifact.sizeBytes : 0,
                                           state: artifact.storageStatus)
            }
            try execute(
                """
                INSERT INTO server_sync_state(recording_id,state,attempt_count,updated_at_utc)
                VALUES(?,?,0,?)
                ON CONFLICT(recording_id) DO UPDATE SET state=excluded.state,updated_at_utc=excluded.updated_at_utc
                """,
                [.text(remote.id.uuidString), .text(restoredSyncState), .text(now)]
            )
            try execute("UPDATE recordings SET server_sync_state=? WHERE id=?", [.text(restoredSyncState), .text(remote.id.uuidString)])
        }
        return !didExist
    }

    func markRecording(_ id: UUID, status: String, endedAt: Date? = nil) throws {
        try execute(
            "UPDATE recordings SET status=?,ended_at_utc=COALESCE(?,ended_at_utc) WHERE id=?",
            [.text(status), endedAt.map { .text(Self.iso8601($0)) } ?? .null, .text(id.uuidString)]
        )
    }

    func saveSessionQuestionnaire(recordingID: UUID, questionnaire: SessionQuestionnaire, revision: Int? = nil) throws {
        guard let recording = try recording(id: recordingID), recording.endedAtUTC != nil,
              let original = recording.questionnaire,
              questionnaire.validate().isValid, questionnaire.readyForSync,
              questionnaire.animalId == original.animalId, questionnaire.videoRequested == original.videoRequested,
              questionnaire.sessionKind == original.sessionKind else {
            throw WoonaStoreError.invalidData("Session questionnaire is invalid or capture fields changed")
        }
        let json = String(decoding: try Self.sessionQuestionnaireData(questionnaire), as: UTF8.self)
        try transaction {
            try execute("UPDATE recordings SET questionnaire_json=?,session_label=?,questionnaire_revision=COALESCE(?,questionnaire_revision),questionnaire_dirty=? WHERE id=?",
                        [.text(json), .text(questionnaire.sessionLabel), revision.map { .integer(Int64($0)) } ?? .null, .integer(revision == nil ? 1 : 0), .text(recordingID.uuidString)])
            if revision == nil {
                try execute("UPDATE recordings SET server_sync_state='pending' WHERE id=?", [.text(recordingID.uuidString)])
                try execute("UPDATE server_sync_state SET state='pending',last_error_message=NULL WHERE recording_id=?", [.text(recordingID.uuidString)])
            }
        }
    }

    func saveHeartQuestionnaire(recordingID: UUID, heart: HeartQuestionnaire) throws {
        guard heart.validate().isValid, let recording = try recording(id: recordingID), recording.endedAtUTC != nil,
              var questionnaire = recording.questionnaire, questionnaire.sessionKind == "heart" else {
            throw WoonaStoreError.invalidData("Анкета не заполнена или запись ещё не завершена")
        }
        questionnaire.heartQuestionnaire = heart.normalized()
        try saveSessionQuestionnaire(recordingID: recordingID, questionnaire: questionnaire)
    }

    func attachReference(recordingID: UUID, type: String, sourceURL: URL, metadata: ReferenceMetadata) throws {
        guard ["ecg", "heart_rate", "rr"].contains(type), metadata.validate().isValid,
              let recording = try recording(id: recordingID), recording.endedAtUTC != nil, recording.serverSyncState != "remote" else {
            throw WoonaStoreError.invalidData("Завершите исходную выгрузку и укажите контрольную запись с временной привязкой")
        }
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        let name = "reference-\(UUID().uuidString)-" + String(decoding: sourceURL.lastPathComponent.utf8.suffix(180), as: UTF8.self)
        let target = directory(for: recording).appendingPathComponent(name)
        let temporary = target.appendingPathExtension("part")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: temporary)
            let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { throw WoonaStoreError.invalidData("Контрольный файл пуст") }
            let hash = try Self.sha256File(temporary)
            try FileManager.default.moveItem(at: temporary, to: target)
            let reference = String(data: try Self.encoder.encode(metadata), encoding: .utf8)!
            try transaction {
                try execute("""
                    INSERT INTO artifacts(id,recording_id,type,file_name,relative_path,mime_type,size_bytes,sha256,created_at_utc,reference_metadata_json)
                    VALUES(?,?,?,?,?,'application/octet-stream',?,?,?,?)
                """, [.text(UUID().uuidString), .text(recordingID.uuidString), .text(type), .text(name),
                    .text(recording.relativeDirectory + "/" + name), .integer(size), .text(hash), .text(Self.iso8601(Date())), .text(reference)])
                try execute("UPDATE recordings SET server_sync_state='pending' WHERE id=?", [.text(recordingID.uuidString)])
                try execute("UPDATE server_sync_state SET state='pending',last_error_message=NULL WHERE recording_id=?", [.text(recordingID.uuidString)])
            }
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }

    func recentRecordings(dogID: UUID, limit: Int? = 10) throws -> [WoonaRecording] {
        let statement = try prepare(
            """
            SELECT id,dog_id,dog_profile_version_id,source,status,session_label,
                   video_requested,started_at_utc,ended_at_utc,timezone,
                   questionnaire_json,relative_directory,server_sync_state,app_version,questionnaire_revision,questionnaire_dirty
            FROM recordings WHERE dog_id=? ORDER BY started_at_utc DESC LIMIT ?
            """,
            [.text(dogID.uuidString), .integer(Int64(limit.map { max($0, 0) } ?? -1))]
        )
        defer { sqlite3_finalize(statement) }
        var result: [WoonaRecording] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(try decodeRecording(statement)) }
        return result
    }

    func acceptServerProfile(dogID: UUID, version: ServerProfileVersion) throws {
        let json = String(decoding: try Self.dogQuestionnaireData(version.questionnaire), as: UTF8.self)
        try execute("UPDATE dog_profile_versions SET questionnaire_json=?,content_sha256=? WHERE id=? AND dog_id=?",
                    [.text(json), .text(version.contentSha256), .text(version.id.uuidString), .text(dogID.uuidString)])
    }

    func acceptServerSession(recordingID: UUID, questionnaire: JSONValue) throws {
        let json = String(decoding: try Self.encoder.encode(questionnaire), as: UTF8.self)
        try execute("UPDATE recordings SET questionnaire_json=? WHERE id=?", [.text(json), .text(recordingID.uuidString)])
    }

    @discardableResult
    func applyServerDeletions(_ entities: [ServerDeletion], accountID: String? = nil) throws -> Int {
        let scopedDogIDs = Set(try profiles().filter { $0.accountID == accountID }.map { $0.id.uuidString })
        func retired(_ kind: String, _ id: String) -> Bool {
            let hash = Self.sha256(Data(id.lowercased().utf8))
            return entities.contains { $0.kind == kind && $0.id_sha256 == hash }
        }
        let statement = try prepare("SELECT id,dog_id,status,relative_directory FROM recordings")
        var ids: [String] = []
        var paths: [URL] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if !scopedDogIDs.contains(columnText(statement, 1)) || ["preparing", "recording"].contains(columnText(statement, 2)) { continue }
            if retired("recording", columnText(statement, 0)) || retired("dog", columnText(statement, 1)) {
                ids.append(columnText(statement, 0))
                let path = rootDirectory.appendingPathComponent(columnText(statement, 3)).resolvingSymlinksInPath().standardizedFileURL
                guard path.path.hasPrefix(rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
                    sqlite3_finalize(statement)
                    throw WoonaStoreError.invalidData("Invalid retired recording path")
                }
                paths.append(path)
            }
        }
        sqlite3_finalize(statement)
        for path in paths where FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        try transaction {
            for id in ids { try execute("DELETE FROM recordings WHERE id=?", [.text(id)]) }
            let artifacts = try prepare("SELECT a.id,a.relative_path,r.dog_id FROM artifacts a JOIN recordings r ON r.id=a.recording_id WHERE r.status NOT IN ('preparing','recording')")
            var deletedArtifacts: [(String,URL)] = []
            while sqlite3_step(artifacts) == SQLITE_ROW {
                if scopedDogIDs.contains(columnText(artifacts,2)) && retired("artifact",columnText(artifacts,0)) {
                    let path=rootDirectory.appendingPathComponent(columnText(artifacts,1)).resolvingSymlinksInPath().standardizedFileURL
                    guard path.path.hasPrefix(rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path+"/") else {
                        sqlite3_finalize(artifacts);throw WoonaStoreError.invalidData("Invalid retired artifact path")
                    }
                    deletedArtifacts.append((columnText(artifacts,0),path))
                }
            }
            sqlite3_finalize(artifacts)
            for (id,path) in deletedArtifacts {
                if FileManager.default.fileExists(atPath:path.path) { try FileManager.default.removeItem(at:path) }
                try execute("DELETE FROM artifacts WHERE id=?",[.text(id)])
            }
            let current = try prepare("SELECT current_profile_version_id FROM dogs")
            var currentVersions = Set<String>()
            while sqlite3_step(current) == SQLITE_ROW { currentVersions.insert(columnText(current,0)) }
            sqlite3_finalize(current)
            let versions = try prepare("SELECT id,dog_id FROM dog_profile_versions WHERE id NOT IN (SELECT dog_profile_version_id FROM recordings)")
            var deletedVersions: [String] = []
            while sqlite3_step(versions) == SQLITE_ROW {
                if scopedDogIDs.contains(columnText(versions, 1)) && (retired("dog", columnText(versions, 1)) || (retired("profile",columnText(versions,0)) && !currentVersions.contains(columnText(versions,0)))) { deletedVersions.append(columnText(versions, 0)) }
            }
            sqlite3_finalize(versions)
            for id in deletedVersions { try execute("DELETE FROM dog_profile_versions WHERE id=?", [.text(id)]) }
            let dogs = try prepare("SELECT id FROM dogs WHERE id NOT IN (SELECT dog_id FROM recordings) AND id NOT IN (SELECT dog_id FROM dog_profile_versions)")
            var deletedDogs: [String] = []
            while sqlite3_step(dogs) == SQLITE_ROW { if scopedDogIDs.contains(columnText(dogs, 0)) && retired("dog", columnText(dogs, 0)) { deletedDogs.append(columnText(dogs, 0)) } }
            sqlite3_finalize(dogs)
            for id in deletedDogs { try execute("DELETE FROM dogs WHERE id=?", [.text(id)]) }
        }
        return ids.count
    }

    func recording(id: UUID) throws -> WoonaRecording? {
        let statement = try prepare(
            """
            SELECT id,dog_id,dog_profile_version_id,source,status,session_label,
                   video_requested,started_at_utc,ended_at_utc,timezone,
                   questionnaire_json,relative_directory,server_sync_state,app_version,questionnaire_revision,questionnaire_dirty
            FROM recordings WHERE id=? LIMIT 1
            """,
            [.text(id.uuidString)]
        )
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? try decodeRecording(statement) : nil
    }

    func directory(for recording: WoonaRecording) -> URL {
        rootDirectory.appendingPathComponent(recording.relativeDirectory, isDirectory: true)
    }

    func finalize(
        recording: WoonaRecording,
        status: String,
        files: [(type: String, source: URL, name: String, mime: String)],
        syncJSON: Data
    ) throws {
        let directory = directory(for: recording)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var finalFiles: [(String, URL, String)] = []
        for file in files where FileManager.default.fileExists(atPath: file.source.path) {
            let target = directory.appendingPathComponent(file.name)
            if file.source.standardizedFileURL != target.standardizedFileURL {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: file.source, to: target)
            }
            finalFiles.append((file.type, target, file.mime))
        }
        let syncTarget = directory.appendingPathComponent("sync.json")
        let temporary = directory.appendingPathComponent("sync.json.tmp")
        try syncJSON.write(to: temporary, options: .atomic)
        try? FileManager.default.removeItem(at: syncTarget)
        try FileManager.default.moveItem(at: temporary, to: syncTarget)
        finalFiles.append(("sync", syncTarget, "application/json"))

        let now = Self.iso8601(Date())
        try transaction {
            for (type, url, mime) in finalFiles {
                let relative = rootDirectory.standardizedFileURL.path == url.deletingLastPathComponent().standardizedFileURL.path
                    ? url.lastPathComponent
                    : url.path.replacingOccurrences(of: rootDirectory.path + "/", with: "")
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                let hash = try Self.sha256File(url)
                try execute(
                    """
                    INSERT INTO artifacts(
                      id,recording_id,type,file_name,relative_path,mime_type,
                      size_bytes,sha256,upload_state,uploaded_bytes,created_at_utc
                    ) VALUES(?,?,?,?,?,?,?,?,'pending',0,?)
                    ON CONFLICT(recording_id,relative_path) DO UPDATE SET
                      size_bytes=excluded.size_bytes,sha256=excluded.sha256,
                      upload_state='pending',uploaded_bytes=0
                    """,
                    [
                        .text(UUID().uuidString), .text(recording.id.uuidString), .text(type),
                        .text(url.lastPathComponent), .text(relative), .text(mime),
                        .integer(size), .text(hash), .text(now),
                    ]
                )
            }
            try execute(
                "INSERT OR REPLACE INTO recording_sync(recording_id,sync_json,updated_at_utc) VALUES(?,?,?)",
                [.text(recording.id.uuidString), .text(String(data: syncJSON, encoding: .utf8)!), .text(now)]
            )
            try execute(
                "UPDATE recordings SET status=?,ended_at_utc=?,server_sync_state='pending' WHERE id=?",
                [.text(status), .text(now), .text(recording.id.uuidString)]
            )
            if var questionnaire = recording.questionnaire, questionnaire.schemaVersion == 2 && recording.source == "live" {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: recording.timezone)
                formatter.dateFormat = "HH:mm"
                questionnaire.endTime = formatter.string(from: Date())
                let parser = ISO8601DateFormatter()
                parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let start = parser.date(from: recording.startedAtUTC) ?? ISO8601DateFormatter().date(from: recording.startedAtUTC) {
                    questionnaire.durationMinutes = max(0, Date().timeIntervalSince(start) / 60)
                }
                let json = String(data: try Self.sessionQuestionnaireData(questionnaire), encoding: .utf8)!
                try execute("UPDATE recordings SET questionnaire_json=? WHERE id=?", [.text(json), .text(recording.id.uuidString)])
            }
            try execute(
                "INSERT OR REPLACE INTO server_sync_state(recording_id,state,attempt_count,updated_at_utc) VALUES(?,'pending',0,?)",
                [.text(recording.id.uuidString), .text(now)]
            )
        }
    }

    func artifacts(recordingID: UUID) throws -> [LocalArtifact] {
        let statement = try prepare(
            "SELECT id,recording_id,type,file_name,relative_path,mime_type,size_bytes,sha256,uploaded_bytes,reference_metadata_json,upload_state FROM artifacts WHERE recording_id=? ORDER BY created_at_utc,relative_path",
            [.text(recordingID.uuidString)]
        )
        defer { sqlite3_finalize(statement) }
        var values: [LocalArtifact] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: columnText(statement, 0)),
                  let recordingID = UUID(uuidString: columnText(statement, 1)) else { throw WoonaStoreError.invalidData("Invalid artifact UUID") }
            values.append(
                LocalArtifact(
                    id: id,
                    recordingID: recordingID,
                    type: columnText(statement, 2),
                    fileName: columnText(statement, 3),
                    relativePath: columnText(statement, 4),
                    mimeType: columnText(statement, 5),
                    sizeBytes: sqlite3_column_int64(statement, 6),
                    sha256: columnText(statement, 7),
                    uploadedBytes: sqlite3_column_int64(statement, 8),
                    referenceMetadata: columnOptionalText(statement, 9).flatMap {
                        try? JSONDecoder().decode(ReferenceMetadata.self, from: Data($0.utf8))
                    },
                    uploadState: columnText(statement, 10)
                )
            )
        }
        return values
    }

    func localRemovalPlan(recordingID: UUID, verifiedRemote remote: ServerRecordingDetail) throws -> LocalRecordingRemoval {
        guard let local = try recording(id: recordingID),
              ["completed", "failed", "interrupted"].contains(local.status),
              local.serverSyncState == "synced", !local.questionnaireDirty else { throw WoonaStoreError.invalidData("local_copy_not_synced") }
        guard remote.id == local.id, remote.dogId == local.dogID, remote.ingestStatus == "complete",
              ["completed", "failed", "interrupted"].contains(remote.captureStatus),
              remote.receiptSha256?.isEmpty == false, remote.serverVerifiedAtUtc?.isEmpty == false else { throw WoonaStoreError.invalidData("server_copy_unverified") }
        let localArtifacts = try artifacts(recordingID: recordingID)
        guard !localArtifacts.isEmpty, localArtifacts.allSatisfy({ artifact in
            remote.artifacts.contains { saved in
                saved.fileName == artifact.fileName && saved.type == artifact.type &&
                saved.sizeBytes == artifact.sizeBytes && saved.sha256 == artifact.sha256 && saved.storageStatus == "available"
            }
        }) else { throw WoonaStoreError.invalidData("server_copy_unverified") }
        let directory = self.directory(for: local).resolvingSymlinksInPath().standardizedFileURL
        guard directory.path.hasPrefix(rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw WoonaStoreError.invalidData("local_copy_unsafe_path") }
        let files = localArtifacts.map { artifact in RecordingArchive.File(url: rootDirectory.appendingPathComponent(artifact.relativePath), size: artifact.sizeBytes, sha256: artifact.sha256) }
        // Reconcile canonical server artifact IDs so later downloads use current IDs.
        _ = try restoreRemoteRecording(remote)
        return LocalRecordingRemoval(directory: directory, files: files)
    }

    func missingArtifacts(recordingID: UUID) throws -> [LocalArtifact] {
        try artifacts(recordingID: recordingID).filter {
            !FileManager.default.fileExists(atPath: rootDirectory.appendingPathComponent($0.relativePath).path)
        }
    }

    func syncJSON(recordingID: UUID) throws -> Data? {
        let statement = try prepare("SELECT sync_json FROM recording_sync WHERE recording_id=?", [.text(recordingID.uuidString)])
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Data(columnText(statement, 0).utf8) : nil
    }

    func recordingSyncError(recordingID: UUID) throws -> String? {
        let statement = try prepare("SELECT COALESCE(NULLIF(last_error_message,''),last_error_code) FROM server_sync_state WHERE recording_id=? AND state IN ('retryable_error','permanent_error')", [.text(recordingID.uuidString)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return columnText(statement, 0)
    }

    func recordingArchive(recordingID: UUID) throws -> RecordingArchive {
        guard let recording = try recording(id: recordingID),
              let profile = try profile(dogID: recording.dogID, versionID: recording.profileVersionID) else {
            throw WoonaStoreError.invalidData("Recording or its saved dog questionnaire is missing")
        }
        guard !["preparing", "recording"].contains(recording.status) else {
            throw WoonaStoreError.invalidData("Stop and finalize this recording before exporting")
        }
        let artifacts = try artifacts(recordingID: recordingID)
        let root = rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var files: [RecordingArchive.File] = []
        var entries: [[String: Any]] = []
        var missing: [String] = []
        for artifact in artifacts {
            let file = rootDirectory.appendingPathComponent(artifact.relativePath).resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(root), artifact.fileName == file.lastPathComponent,
                  artifact.fileName != "manifest.json", !artifact.fileName.contains("\\") else {
                throw WoonaStoreError.invalidData("Invalid recording artifact path: \(artifact.fileName)")
            }
            guard FileManager.default.fileExists(atPath: file.path) else { missing.append(artifact.fileName); continue }
            guard !files.contains(where: { $0.url.lastPathComponent == file.lastPathComponent }) else {
                throw WoonaStoreError.invalidData("Duplicate recording artifact name: \(artifact.fileName)")
            }
            files.append(.init(url: file, size: artifact.sizeBytes, sha256: artifact.sha256))
            entries.append(["name": artifact.fileName, "size": artifact.sizeBytes, "sha256": artifact.sha256, "type": artifact.type])
        }
        guard !files.isEmpty else { throw WoonaStoreError.invalidData("No local files for this recording; download its files first") }
        let statement = try prepare("SELECT questionnaire_json FROM recordings WHERE id=?", [.text(recordingID.uuidString)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw WoonaStoreError.invalidData("Recording questionnaire is missing") }
        let questionnaire = try JSONSerialization.jsonObject(with: Data(columnText(statement, 0).utf8))
        let synchronization: Any = try syncJSON(recordingID: recordingID).map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull()
        let parser = ISO8601DateFormatter()
        let started = parser.date(from: recording.startedAtUTC)
        parser.formatOptions.insert(.withFractionalSeconds)
        let start = started ?? parser.date(from: recording.startedAtUTC)
        let manifest: [String: Any] = [
            "createdAtMillis": Int64(Date().timeIntervalSince1970 * 1_000),
            "sessionStartMillis": start.map { Int64($0.timeIntervalSince1970 * 1_000) } as Any? ?? NSNull(),
            "profile": ["id": profile.id.uuidString, "numberOrName": profile.numberOrName,
                        "questionnaire": try JSONSerialization.jsonObject(with: Self.dogQuestionnaireData(profile.questionnaire))],
            "recording": ["id": recording.id.uuidString, "source": recording.source, "status": recording.status,
                          "sessionLabel": recording.sessionLabel, "timezone": recording.timezone,
                          "startedAtUtc": recording.startedAtUTC, "serverSyncState": recording.serverSyncState,
                          "questionnaire": questionnaire, "appVersion": recording.appVersion ?? "unknown"],
            "synchronization": synchronization, "files": entries, "missingFiles": missing,
        ]
        let label = "woona_\(profile.numberOrName)_\(recording.sessionLabel)".unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) ? String($0) : "_"
        }.joined()
        return RecordingArchive(files: files, manifest: try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]),
                                name: String(label.prefix(48)) + "_" + recording.id.uuidString)
    }

    func pendingRecordings() throws -> [WoonaRecording] {
        let statement = try prepare(
            """
            SELECT id,dog_id,dog_profile_version_id,source,status,session_label,
                   video_requested,started_at_utc,ended_at_utc,timezone,
                   questionnaire_json,relative_directory,server_sync_state,app_version,questionnaire_revision,questionnaire_dirty
            FROM recordings
            WHERE status IN ('completed','failed','interrupted')
              AND server_sync_state IN ('pending','retryable_error')
            ORDER BY started_at_utc
            """
        )
        defer { sqlite3_finalize(statement) }
        var values: [WoonaRecording] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let recording = try decodeRecording(statement)
            if recording.questionnaire?.readyForSync != false { values.append(recording) }
        }
        return values
    }

    func updateArtifactProgress(_ id: UUID, uploadedBytes: Int64, state: String) throws {
        try execute(
            "UPDATE artifacts SET uploaded_bytes=?,upload_state=? WHERE id=?",
            [.integer(uploadedBytes), .text(state), .text(id.uuidString)]
        )
    }

    func updateRecordingSync(_ id: UUID, state: String, error: Error? = nil) throws {
        let hasPendingArtifacts = try artifacts(recordingID: id).contains { $0.uploadState != "available" }
        let state = state == "synced" && hasPendingArtifacts ? "pending" : state
        let now = Self.iso8601(Date())
        try transaction {
            try execute(
                "UPDATE recordings SET server_sync_state=? WHERE id=?",
                [.text(state), .text(id.uuidString)]
            )
            try execute(
                """
                INSERT INTO server_sync_state(recording_id,state,attempt_count,last_error_message,updated_at_utc)
                VALUES(?,?,1,?,?)
                ON CONFLICT(recording_id) DO UPDATE SET
                  state=excluded.state,
                  attempt_count=server_sync_state.attempt_count+1,
                  last_error_message=excluded.last_error_message,
                  updated_at_utc=excluded.updated_at_utc
                """,
                [.text(id.uuidString), .text(state), error.map { .text($0.localizedDescription) } ?? .null, .text(now)]
            )
        }
    }

    @discardableResult
    func recoverInterruptedUploads(excluding activeRecordings: Set<UUID>) throws -> Int {
        let statement = try prepare("SELECT id FROM recordings WHERE server_sync_state='uploading' UNION SELECT recording_id FROM server_sync_state WHERE state='uploading'")
        var ids: [UUID] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let id = UUID(uuidString: columnText(statement, 0)), !activeRecordings.contains(id) { ids.append(id) }
            result = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        guard result == SQLITE_DONE else { throw sqliteError() }
        guard !ids.isEmpty else { return 0 }
        let now = Self.iso8601(Date())
        try transaction {
            for id in ids {
                try execute("UPDATE recordings SET server_sync_state='pending' WHERE id=? AND server_sync_state='uploading'", [.text(id.uuidString)])
                try execute("""
                    UPDATE server_sync_state SET state='pending',updated_at_utc=?,last_error_code='orphaned_upload_recovered',
                        last_error_message='orphaned_upload_recovered: Previous upload was interrupted and has no live operation. Retry resumes from confirmed progress; local files are preserved.'
                    WHERE recording_id=? AND state='uploading'
                    """, [.text(now), .text(id.uuidString)])
            }
        }
        return ids.count
    }

    func resetFailedSync() throws {
        let now = Self.iso8601(Date())
        try transaction {
            try execute(
                "UPDATE recordings SET server_sync_state='pending' WHERE server_sync_state IN ('retryable_error','permanent_error')"
            )
            try execute(
                "UPDATE server_sync_state SET state='pending',updated_at_utc=? WHERE state IN ('retryable_error','permanent_error')",
                [.text(now)]
            )
        }
    }

    private func decodeRecording(_ statement: OpaquePointer?) throws -> WoonaRecording {
        guard let id = UUID(uuidString: columnText(statement, 0)),
              let dogID = UUID(uuidString: columnText(statement, 1)),
              let versionID = UUID(uuidString: columnText(statement, 2)) else {
            throw WoonaStoreError.invalidData("Invalid recording UUID")
        }
        let sync = try syncJSON(recordingID: id).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
        return WoonaRecording(
            id: id,
            dogID: dogID,
            profileVersionID: versionID,
            source: columnText(statement, 3),
            status: columnText(statement, 4),
            sessionLabel: columnText(statement, 5),
            videoRequested: sqlite3_column_int(statement, 6) == 1,
            startedAtUTC: columnText(statement, 7),
            endedAtUTC: columnOptionalText(statement, 8),
            timezone: columnText(statement, 9),
            questionnaire: try? JSONDecoder().decode(SessionQuestionnaire.self, from: Data(columnText(statement, 10).utf8)),
            relativeDirectory: columnText(statement, 11),
            serverSyncState: columnText(statement, 12),
            appVersion: columnOptionalText(statement, 13),
            questionnaireRevision: Int(sqlite3_column_int64(statement, 14)),
            questionnaireDirty: sqlite3_column_int(statement, 15) == 1,
            captureErrorCode: sync?["captureErrorCode"] as? String,
            captureErrorMessage: sync?["captureErrorMessage"] as? String
        )
    }

    private func existingArtifact(id: UUID) throws -> (recordingID: UUID, sha256: String)? {
        let statement = try prepare("SELECT recording_id,sha256 FROM artifacts WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let recordingID = UUID(uuidString: columnText(statement, 0)) else { return nil }
        return (recordingID, columnText(statement, 1))
    }

    private func existingProfileVersion(id: UUID) throws -> (dogID: UUID, sha256: String)? {
        let statement = try prepare("SELECT dog_id,content_sha256 FROM dog_profile_versions WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let dogID = UUID(uuidString: columnText(statement, 0)) else { return nil }
        return (dogID, columnText(statement, 1))
    }

    private func migrate() throws {
        try execute("PRAGMA user_version=6")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS dogs(
              id TEXT PRIMARY KEY,current_profile_version_id TEXT NOT NULL,
              number_or_name TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,
              created_at_utc TEXT NOT NULL,updated_at_utc TEXT NOT NULL,
              archived_at_utc TEXT
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS dog_profile_versions(
              id TEXT PRIMARY KEY,dog_id TEXT NOT NULL REFERENCES dogs(id),
              schema_version INTEGER NOT NULL,validation_state TEXT NOT NULL,
              questionnaire_json TEXT NOT NULL,content_sha256 TEXT NOT NULL,
              client_created_at_utc TEXT NOT NULL,superseded_at_utc TEXT
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS recordings(
              id TEXT PRIMARY KEY,dog_id TEXT NOT NULL REFERENCES dogs(id),
              dog_profile_version_id TEXT NOT NULL REFERENCES dog_profile_versions(id),
              source TEXT NOT NULL CHECK(source IN ('live','replay')),
              status TEXT NOT NULL CHECK(status IN ('preparing','recording','completed','failed','interrupted')),
              session_label TEXT NOT NULL,video_requested INTEGER NOT NULL,
              started_at_utc TEXT NOT NULL,ended_at_utc TEXT,timezone TEXT NOT NULL,
              questionnaire_json TEXT NOT NULL,relative_directory TEXT NOT NULL UNIQUE,
              server_sync_state TEXT NOT NULL DEFAULT 'pending'
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS recording_sync(
              recording_id TEXT PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
              sync_json TEXT NOT NULL,updated_at_utc TEXT NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS artifacts(
              id TEXT PRIMARY KEY,recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
              type TEXT NOT NULL,file_name TEXT NOT NULL,relative_path TEXT NOT NULL,
              mime_type TEXT NOT NULL,size_bytes INTEGER NOT NULL,sha256 TEXT NOT NULL,
              upload_state TEXT NOT NULL DEFAULT 'pending',uploaded_bytes INTEGER NOT NULL DEFAULT 0,
              created_at_utc TEXT NOT NULL,UNIQUE(recording_id,relative_path)
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS server_sync_state(
              recording_id TEXT PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
              state TEXT NOT NULL DEFAULT 'pending',attempt_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at_utc TEXT,last_error_code TEXT,last_error_message TEXT,
              server_receipt_sha256 TEXT,updated_at_utc TEXT NOT NULL
            )
            """
        )
        try ensureReferenceColumn()
        let columns = try prepare("PRAGMA table_info(recordings)")
        defer { sqlite3_finalize(columns) }
        var hasAppVersion = false
        while sqlite3_step(columns) == SQLITE_ROW { if columnText(columns, 1) == "app_version" { hasAppVersion = true } }
        if !hasAppVersion { try execute("ALTER TABLE recordings ADD COLUMN app_version TEXT") }
        for (table, column, definition) in [("dogs", "account_id", "TEXT"), ("recordings", "questionnaire_revision", "INTEGER NOT NULL DEFAULT 1"), ("recordings", "questionnaire_dirty", "INTEGER NOT NULL DEFAULT 0")] {
            let columns = try prepare("PRAGMA table_info(\(table))")
            var found = false
            while sqlite3_step(columns) == SQLITE_ROW { if columnText(columns, 1) == column { found = true } }
            sqlite3_finalize(columns)
            if !found { try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)") }
        }
    }

    private func ensureReferenceColumn() throws {
        let statement = try prepare("PRAGMA table_info(artifacts)")
        defer { sqlite3_finalize(statement) }
        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW { if columnText(statement, 1) == "reference_metadata_json" { exists = true } }
        if !exists { try execute("ALTER TABLE artifacts ADD COLUMN reference_metadata_json TEXT") }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private enum SQLiteValue { case text(String), integer(Int64), null }

    private func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    private func prepare(_ sql: String, _ values: [SQLiteValue] = []) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw sqliteError() }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func sqliteError() -> WoonaStoreError {
        WoonaStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        String(cString: sqlite3_column_text(statement, index))
    }

    private func columnOptionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : columnText(statement, index)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    static func dogQuestionnaireData(_ questionnaire: DogQuestionnaire) throws -> Data {
        try questionnaireData(
            questionnaire,
            nullKeys: [
                "breedName", "resembles", "ageYears", "ageMonths", "weightKg",
                "bodyConditionScore", "neckCircumferenceCm", "shavedAreasDetails",
                "diagnosesDetails", "housingDetails", "walksDescription", "notes",
            ] + (questionnaire.schemaVersion == 2 ? ["animalId", "species", "savedAtLocal", "diseaseCategory", "diseaseCategoryDetails", "chronicLameness", "medications", "history", "specialistName"] : [])
        )
    }
    static func sessionQuestionnaireData(_ questionnaire: SessionQuestionnaire) throws -> Data {
        try questionnaireData(
            questionnaire,
            nullKeys: [
                "activityDetails", "surfaceDetails", "airTemperatureC",
                "sensorPositionDetails", "preMeasurementStateDetails", "pulseBpm",
                "respirationPerMinute", "bodyTemperatureC", "measurementAtUtc",
            ] + (questionnaire.schemaVersion == 2 ? ["animalId", "savedAtLocal", "sessionDate", "startTime", "endTime", "durationMinutes", "lastMedicationAt", "notes", "specialistName"] : [])
        )
    }
    private static func questionnaireData<T: Encodable>(_ questionnaire: T, nullKeys: [String]) throws -> Data {
        guard var value = try JSONSerialization.jsonObject(with: encoder.encode(questionnaire)) as? [String: Any] else {
            throw WoonaStoreError.invalidData("Questionnaire JSON is invalid")
        }
        nullKeys.forEach { if value[$0] == nil { value[$0] = NSNull() } }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    static func iso8601(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)


struct HeartAnswer: Codable, Equatable, Hashable {
    let key: String
    let text: String
}

struct HeartBpm: Codable, Equatable {
    var bpm: Double
    var measuredAtUtc: String
}

struct HeartQuestionnaire: Codable, Equatable {
    var schemaVersion = 1
    var knownHeartCondition: HeartAnswer?
    var heartRelevantMedication: HeartAnswer?
    var preRecordingState: HeartAnswer?
    var actualActivity: HeartAnswer?
    var acuteHeartRateFactors: [HeartAnswer] = []
    var referenceMethod: HeartAnswer?
    var knownHeartConditionDetails: String?
    var heartRelevantMedicationDetails: String?
    var referenceArtifact: String?
    var referenceBpm: HeartBpm?

    static let options: [String: [HeartAnswer]] = [
        "knownHeartCondition": [.init(key: "no", text: "Нет"), .init(key: "yes", text: "Да"), .init(key: "unknown", text: "Неизвестно")],
        "heartRelevantMedication": [.init(key: "no", text: "Нет"), .init(key: "yes", text: "Да"), .init(key: "unknown", text: "Неизвестно")],
        "preRecordingState": [.init(key: "sleeping", text: "Спала"), .init(key: "lying_calm", text: "Спокойно лежала"), .init(key: "awake_calm", text: "Спокойно бодрствовала"), .init(key: "active", text: "Гуляла, бегала или играла"), .init(key: "unknown", text: "Неизвестно")],
        "actualActivity": [.init(key: "rest", text: "Спала или находилась в покое"), .init(key: "walking", text: "Ходила"), .init(key: "running_playing", text: "Бегала или играла"), .init(key: "changing", text: "Активность менялась"), .init(key: "unknown", text: "Неизвестно")],
        "acuteHeartRateFactors": [.init(key: "none", text: "Нет"), .init(key: "stress", text: "Стресс или испуг"), .init(key: "pain", text: "Боль"), .init(key: "overheating", text: "Перегрев"), .init(key: "unknown", text: "Неизвестно")],
        "referenceMethod": [.init(key: "ecg", text: "ЭКГ с временными метками"), .init(key: "polar_rr", text: "Polar с интервалами между ударами и временными метками"), .init(key: "bpm_only", text: "Только число ЧСС, измеренное вручную или прибором"), .init(key: "none", text: "Нет"), .init(key: "unknown", text: "Неизвестно")],
    ]

    func validate() -> QuestionnaireValidation {
        var errors: [String: String] = [:]
        let answers = ["knownHeartCondition": knownHeartCondition, "heartRelevantMedication": heartRelevantMedication,
            "preRecordingState": preRecordingState, "actualActivity": actualActivity, "referenceMethod": referenceMethod]
        for (key, answer) in answers {
            if answer == nil || !Self.options[key]!.contains(answer!) { errors[key] = "Выберите ответ" }
        }
        let keys = acuteHeartRateFactors.map(\.key)
        if keys.isEmpty || Set(keys).count != keys.count || acuteHeartRateFactors.contains(where: { !Self.options["acuteHeartRateFactors"]!.contains($0) }) ||
            (keys.count > 1 && keys.contains(where: { ["none", "unknown"].contains($0) })) {
            errors["acuteHeartRateFactors"] = "Выберите факторы; Нет и Неизвестно выбираются отдельно"
        }
        if ["ecg", "polar_rr"].contains(referenceMethod?.key ?? ""), (referenceArtifact ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors["referenceArtifact"] = "Укажите запись и временную привязку"
        }
        if referenceMethod?.key == "bpm_only" {
            if referenceBpm == nil || !referenceBpm!.bpm.isFinite || referenceBpm!.bpm <= 0 { errors["referenceBpm"] = "Введите положительную ЧСС" }
            if ReferenceMetadata.date(referenceBpm?.measuredAtUtc ?? "") == nil { errors["referenceMeasuredAtUtc"] = "Введите время UTC" }
        }
        for detail in [knownHeartConditionDetails, heartRelevantMedicationDetails, referenceArtifact].compactMap({ $0 }) {
            if detail.count > 2000 { errors["details"] = "Максимум 2000 символов" }
        }
        return QuestionnaireValidation(errors: errors)
    }

    func normalized() -> Self {
        var result = self
        if knownHeartCondition?.key != "yes" { result.knownHeartConditionDetails = nil }
        if heartRelevantMedication?.key != "yes" { result.heartRelevantMedicationDetails = nil }
        if !["ecg", "polar_rr"].contains(referenceMethod?.key ?? "") { result.referenceArtifact = nil }
        if referenceMethod?.key != "bpm_only" { result.referenceBpm = nil }
        return result
    }
}

struct ReferenceMetadata: Codable, Equatable, Sendable {
    var source = ""
    var startedAtUtc = ""
    var endedAtUtc = ""
    var offsetFromRecordingMs: Double?
    var notes: String?

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    func validate() -> QuestionnaireValidation {
        var errors: [String: String] = [:]
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source.count > 200 { errors["source"] = "Укажите устройство/источник (до 200 символов)" }
        let start = Self.date(startedAtUtc), end = Self.date(endedAtUtc)
        if start == nil { errors["startedAtUtc"] = "Введите время начала UTC" }
        if end == nil || (start != nil && end! < start!) { errors["endedAtUtc"] = "Введите окончание не раньше начала" }
        if let offsetFromRecordingMs, !offsetFromRecordingMs.isFinite { errors["offsetFromRecordingMs"] = "Введите число или оставьте пустым" }
        if let notes, notes.count > 2000 { errors["notes"] = "Максимум 2000 символов" }
        return QuestionnaireValidation(errors: errors)
    }
}

extension SessionQuestionnaire {
    var readyForSync: Bool { sessionKind != "heart" || heartQuestionnaire?.validate().isValid == true }
}
