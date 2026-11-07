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
        // Python bounds count raw code points, not Swift grapheme clusters or folded output.
        if AnimalIdentityKey.bytes(animalId ?? "").isEmpty || (animalId ?? "").unicodeScalars.count > 100 { errors["animalId"] = "Укажите ID животного (до 100 символов)" }
        if AnimalIdentityKey.bytes(numberOrName).isEmpty || numberOrName.unicodeScalars.count > 100 { errors["numberOrName"] = "Укажите кличку (до 100 символов)" }
        let textFields: [(String, String?, Int)] = [
            ("shelterOrPlace", shelterOrPlace, 200), ("breedName", breedName, 100), ("resembles", resembles, 200),
            ("shavedAreasDetails", shavedAreasDetails, 500), ("diagnosesDetails", diagnosesDetails, 2000),
            ("housingDetails", housingDetails, 500), ("walksDescription", walksDescription, 500),
            ("notes", notes, 2000), ("medications", medications, 2000), ("history", history, 2000),
            ("specialistName", specialistName, 2000), ("diseaseCategory", diseaseCategory, 2000),
            ("diseaseCategoryDetails", diseaseCategoryDetails, 2000),
            ("species", species, 2000), ("savedAtLocal", savedAtLocal, 2000),
            ("chronicLameness", chronicLameness, 2000),
            ("breedStatus", breedStatus, 2000), ("size", size, 2000),
            ("ageStatus", ageStatus, 2000), ("ageSource", ageSource, 2000), ("sex", sex, 2000),
            ("sterilizationStatus", sterilizationStatus, 2000), ("weightStatus", weightStatus, 2000),
            ("bodyConditionStatus", bodyConditionStatus, 2000), ("muscleMass", muscleMass, 2000),
            ("neckCircumferenceStatus", neckCircumferenceStatus, 2000), ("coatLength", coatLength, 2000),
            ("undercoat", undercoat, 2000), ("shavedAreasStatus", shavedAreasStatus, 2000),
            ("diagnosesStatus", diagnosesStatus, 2000), ("housing", housing, 2000),
            ("walksStatus", walksStatus, 2000), ("cohabitants", cohabitants, 2000),
            ("shelterPermission", shelterPermission, 2000), ("notesStatus", notesStatus, 2000),
        ]
        for (key, value, limit) in textFields {
            if let value, value.unicodeScalars.count > limit { errors[key] = "Максимум \(limit) символов" }
        }
        if observedSigns.count > 100 { errors["observedSigns"] = "Максимум 100 вариантов" }
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
        if AnimalIdentityKey.bytes(sessionLabel).isEmpty || sessionLabel.unicodeScalars.count > 100 { errors["sessionLabel"] = "Укажите номер сессии (до 100 символов)" }
        let textFields: [(String, String?, Int)] = [
            ("operatorName", operatorName, 150), ("activityDetails", activityDetails, 1000),
            ("surfaceDetails", surfaceDetails, 300), ("sensorPositionDetails", sensorPositionDetails, 300),
            ("preMeasurementStateDetails", preMeasurementStateDetails, 500), ("notes", notes, 2000),
            ("lastMedicationAt", lastMedicationAt, 2000), ("specialistName", specialistName, 2000),
            ("savedAtLocal", savedAtLocal, 2000), ("animalId", animalId, 2000),
            ("sessionDate", sessionDate, 2000), ("startTime", startTime, 2000), ("endTime", endTime, 2000),
            ("activityGroup", activityGroup, 2000), ("activityType", activityType, 2000),
            ("location", location, 2000), ("surface", surface, 2000),
            ("airTemperatureStatus", airTemperatureStatus, 2000), ("sensorPosition", sensorPosition, 2000),
            ("collarTightness", collarTightness, 2000), ("preMeasurementState", preMeasurementState, 2000),
            ("pulseStatus", pulseStatus, 2000), ("respirationStatus", respirationStatus, 2000),
            ("bodyTemperatureStatus", bodyTemperatureStatus, 2000),
        ]
        for (key, value, limit) in textFields {
            if let value, value.unicodeScalars.count > limit { errors[key] = "Максимум \(limit) символов" }
        }
        let activities = plannedActivities ?? []
        // Arrays use raw scalar lengths and exact string equality, even in heart mode.
        if plannedActivities == nil || (sessionKind != "heart" && activities.isEmpty) || activities.count > 30 || activities.contains(where: { $0.isEmpty || $0.unicodeScalars.count > 100 }) || Set(activities.map { Array($0.utf8) }).count != activities.count { errors["plannedActivities"] = "Выберите формат записи" }
        if let sessionKind, !["heart", "activity"].contains(sessionKind) { errors["sessionKind"] = "Выберите вид сессии" }
        if let heartQuestionnaire { errors.merge(heartQuestionnaire.validate().errors) { _, new in new } }
        let selectedSurfaces = surfaces ?? []
        if selectedSurfaces.count > 30 || selectedSurfaces.contains(where: { $0.isEmpty || $0.unicodeScalars.count > 100 }) || Set(selectedSurfaces.map { Array($0.utf8) }).count != selectedSurfaces.count { errors["surfaces"] = "Проверьте поверхности" }
        if let airTemperatureC, !airTemperatureC.isFinite || !(-60...70).contains(airTemperatureC) { errors["airTemperatureC"] = "Температура: −60…70 °C" }
        if let pulseBpm, !(20...300).contains(pulseBpm) { errors["pulseBpm"] = "Пульс: 20–300 уд/мин" }
        if let respirationPerMinute, !(1...200).contains(respirationPerMinute) { errors["respirationPerMinute"] = "Дыхание: 1–200 в минуту" }
        if let bodyTemperatureC, !bodyTemperatureC.isFinite || !(30...45).contains(bodyTemperatureC) { errors["bodyTemperatureC"] = "Температура тела: 30–45 °C" }
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

/// Live server Python 3.13.18 / Unicode 15.1.0 `str.strip().casefold()` identity key,
/// NOT a locale comparison, lowercase, NFKC or canonical-equivalence comparison.
/// Scalar mapping and 29 strip whitespace scalars verified against an exhaustive
/// read-only server snapshot (1530 folds), not the host's Unicode version.
/// Hex encoding keeps source reviewable; do not add newer Unicode folds.
/// Compare UTF-8 bytes: Swift String equality otherwise equates canonically
/// equivalent spellings that the server intentionally treats as distinct.
enum AnimalIdentityKey {
    static func bytes(_ value: String) -> [UInt8] {
        func whitespace(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x9...0xD, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
            default: false
            }
        }
        let stripped = value.unicodeScalars.drop(while: whitespace).reversed().drop(while: whitespace).reversed()
        var result = String.UnicodeScalarView()
        for scalar in stripped {
            if let mapped = folding[scalar.value] { result.append(contentsOf: mapped.unicodeScalars) }
            else { result.append(scalar) }
        }
        return Array(String(result).utf8)
    }

    private static let folding: [UInt32: String] = {
        var result: [UInt32: String] = [:]
        for entry in mapping.split(whereSeparator: { $0.isWhitespace }) {
            let pair = entry.split(separator: ":")
            guard let source = UInt32(pair[0], radix: 16) else { continue }
            var target = String.UnicodeScalarView()
            for hex in pair[1].split(separator: ",") {
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { target.append(scalar) }
            }
            result[source] = String(target)
        }
        return result
    }()

    private static let mapping = """
        41:61 42:62 43:63 44:64 45:65 46:66 47:67 48:68 49:69 4A:6A 4B:6B 4C:6C 4D:6D 4E:6E 4F:6F 50:70 51:71 52:72
        53:73 54:74 55:75 56:76 57:77 58:78 59:79 5A:7A B5:3BC C0:E0 C1:E1 C2:E2 C3:E3 C4:E4 C5:E5 C6:E6 C7:E7 C8:E8
        C9:E9 CA:EA CB:EB CC:EC CD:ED CE:EE CF:EF D0:F0 D1:F1 D2:F2 D3:F3 D4:F4 D5:F5 D6:F6 D8:F8 D9:F9 DA:FA DB:FB
        DC:FC DD:FD DE:FE DF:73,73 100:101 102:103 104:105 106:107 108:109 10A:10B 10C:10D 10E:10F 110:111 112:113
        114:115 116:117 118:119 11A:11B 11C:11D 11E:11F 120:121 122:123 124:125 126:127 128:129 12A:12B 12C:12D 12E:12F
        130:69,307 132:133 134:135 136:137 139:13A 13B:13C 13D:13E 13F:140 141:142 143:144 145:146 147:148 149:2BC,6E
        14A:14B 14C:14D 14E:14F 150:151 152:153 154:155 156:157 158:159 15A:15B 15C:15D 15E:15F 160:161 162:163 164:165
        166:167 168:169 16A:16B 16C:16D 16E:16F 170:171 172:173 174:175 176:177 178:FF 179:17A 17B:17C 17D:17E 17F:73
        181:253 182:183 184:185 186:254 187:188 189:256 18A:257 18B:18C 18E:1DD 18F:259 190:25B 191:192 193:260 194:263
        196:269 197:268 198:199 19C:26F 19D:272 19F:275 1A0:1A1 1A2:1A3 1A4:1A5 1A6:280 1A7:1A8 1A9:283 1AC:1AD 1AE:288
        1AF:1B0 1B1:28A 1B2:28B 1B3:1B4 1B5:1B6 1B7:292 1B8:1B9 1BC:1BD 1C4:1C6 1C5:1C6 1C7:1C9 1C8:1C9 1CA:1CC 1CB:1CC
        1CD:1CE 1CF:1D0 1D1:1D2 1D3:1D4 1D5:1D6 1D7:1D8 1D9:1DA 1DB:1DC 1DE:1DF 1E0:1E1 1E2:1E3 1E4:1E5 1E6:1E7 1E8:1E9
        1EA:1EB 1EC:1ED 1EE:1EF 1F0:6A,30C 1F1:1F3 1F2:1F3 1F4:1F5 1F6:195 1F7:1BF 1F8:1F9 1FA:1FB 1FC:1FD 1FE:1FF
        200:201 202:203 204:205 206:207 208:209 20A:20B 20C:20D 20E:20F 210:211 212:213 214:215 216:217 218:219 21A:21B
        21C:21D 21E:21F 220:19E 222:223 224:225 226:227 228:229 22A:22B 22C:22D 22E:22F 230:231 232:233 23A:2C65
        23B:23C 23D:19A 23E:2C66 241:242 243:180 244:289 245:28C 246:247 248:249 24A:24B 24C:24D 24E:24F 345:3B9
        370:371 372:373 376:377 37F:3F3 386:3AC 388:3AD 389:3AE 38A:3AF 38C:3CC 38E:3CD 38F:3CE 390:3B9,308,301 391:3B1
        392:3B2 393:3B3 394:3B4 395:3B5 396:3B6 397:3B7 398:3B8 399:3B9 39A:3BA 39B:3BB 39C:3BC 39D:3BD 39E:3BE 39F:3BF
        3A0:3C0 3A1:3C1 3A3:3C3 3A4:3C4 3A5:3C5 3A6:3C6 3A7:3C7 3A8:3C8 3A9:3C9 3AA:3CA 3AB:3CB 3B0:3C5,308,301 3C2:3C3
        3CF:3D7 3D0:3B2 3D1:3B8 3D5:3C6 3D6:3C0 3D8:3D9 3DA:3DB 3DC:3DD 3DE:3DF 3E0:3E1 3E2:3E3 3E4:3E5 3E6:3E7 3E8:3E9
        3EA:3EB 3EC:3ED 3EE:3EF 3F0:3BA 3F1:3C1 3F4:3B8 3F5:3B5 3F7:3F8 3F9:3F2 3FA:3FB 3FD:37B 3FE:37C 3FF:37D 400:450
        401:451 402:452 403:453 404:454 405:455 406:456 407:457 408:458 409:459 40A:45A 40B:45B 40C:45C 40D:45D 40E:45E
        40F:45F 410:430 411:431 412:432 413:433 414:434 415:435 416:436 417:437 418:438 419:439 41A:43A 41B:43B 41C:43C
        41D:43D 41E:43E 41F:43F 420:440 421:441 422:442 423:443 424:444 425:445 426:446 427:447 428:448 429:449 42A:44A
        42B:44B 42C:44C 42D:44D 42E:44E 42F:44F 460:461 462:463 464:465 466:467 468:469 46A:46B 46C:46D 46E:46F 470:471
        472:473 474:475 476:477 478:479 47A:47B 47C:47D 47E:47F 480:481 48A:48B 48C:48D 48E:48F 490:491 492:493 494:495
        496:497 498:499 49A:49B 49C:49D 49E:49F 4A0:4A1 4A2:4A3 4A4:4A5 4A6:4A7 4A8:4A9 4AA:4AB 4AC:4AD 4AE:4AF 4B0:4B1
        4B2:4B3 4B4:4B5 4B6:4B7 4B8:4B9 4BA:4BB 4BC:4BD 4BE:4BF 4C0:4CF 4C1:4C2 4C3:4C4 4C5:4C6 4C7:4C8 4C9:4CA 4CB:4CC
        4CD:4CE 4D0:4D1 4D2:4D3 4D4:4D5 4D6:4D7 4D8:4D9 4DA:4DB 4DC:4DD 4DE:4DF 4E0:4E1 4E2:4E3 4E4:4E5 4E6:4E7 4E8:4E9
        4EA:4EB 4EC:4ED 4EE:4EF 4F0:4F1 4F2:4F3 4F4:4F5 4F6:4F7 4F8:4F9 4FA:4FB 4FC:4FD 4FE:4FF 500:501 502:503 504:505
        506:507 508:509 50A:50B 50C:50D 50E:50F 510:511 512:513 514:515 516:517 518:519 51A:51B 51C:51D 51E:51F 520:521
        522:523 524:525 526:527 528:529 52A:52B 52C:52D 52E:52F 531:561 532:562 533:563 534:564 535:565 536:566 537:567
        538:568 539:569 53A:56A 53B:56B 53C:56C 53D:56D 53E:56E 53F:56F 540:570 541:571 542:572 543:573 544:574 545:575
        546:576 547:577 548:578 549:579 54A:57A 54B:57B 54C:57C 54D:57D 54E:57E 54F:57F 550:580 551:581 552:582 553:583
        554:584 555:585 556:586 587:565,582 10A0:2D00 10A1:2D01 10A2:2D02 10A3:2D03 10A4:2D04 10A5:2D05 10A6:2D06
        10A7:2D07 10A8:2D08 10A9:2D09 10AA:2D0A 10AB:2D0B 10AC:2D0C 10AD:2D0D 10AE:2D0E 10AF:2D0F 10B0:2D10 10B1:2D11
        10B2:2D12 10B3:2D13 10B4:2D14 10B5:2D15 10B6:2D16 10B7:2D17 10B8:2D18 10B9:2D19 10BA:2D1A 10BB:2D1B 10BC:2D1C
        10BD:2D1D 10BE:2D1E 10BF:2D1F 10C0:2D20 10C1:2D21 10C2:2D22 10C3:2D23 10C4:2D24 10C5:2D25 10C7:2D27 10CD:2D2D
        13F8:13F0 13F9:13F1 13FA:13F2 13FB:13F3 13FC:13F4 13FD:13F5 1C80:432 1C81:434 1C82:43E 1C83:441 1C84:442
        1C85:442 1C86:44A 1C87:463 1C88:A64B 1C90:10D0 1C91:10D1 1C92:10D2 1C93:10D3 1C94:10D4 1C95:10D5
        1C96:10D6 1C97:10D7 1C98:10D8 1C99:10D9 1C9A:10DA 1C9B:10DB 1C9C:10DC 1C9D:10DD 1C9E:10DE 1C9F:10DF 1CA0:10E0
        1CA1:10E1 1CA2:10E2 1CA3:10E3 1CA4:10E4 1CA5:10E5 1CA6:10E6 1CA7:10E7 1CA8:10E8 1CA9:10E9 1CAA:10EA 1CAB:10EB
        1CAC:10EC 1CAD:10ED 1CAE:10EE 1CAF:10EF 1CB0:10F0 1CB1:10F1 1CB2:10F2 1CB3:10F3 1CB4:10F4 1CB5:10F5 1CB6:10F6
        1CB7:10F7 1CB8:10F8 1CB9:10F9 1CBA:10FA 1CBD:10FD 1CBE:10FE 1CBF:10FF 1E00:1E01 1E02:1E03 1E04:1E05 1E06:1E07
        1E08:1E09 1E0A:1E0B 1E0C:1E0D 1E0E:1E0F 1E10:1E11 1E12:1E13 1E14:1E15 1E16:1E17 1E18:1E19 1E1A:1E1B 1E1C:1E1D
        1E1E:1E1F 1E20:1E21 1E22:1E23 1E24:1E25 1E26:1E27 1E28:1E29 1E2A:1E2B 1E2C:1E2D 1E2E:1E2F 1E30:1E31 1E32:1E33
        1E34:1E35 1E36:1E37 1E38:1E39 1E3A:1E3B 1E3C:1E3D 1E3E:1E3F 1E40:1E41 1E42:1E43 1E44:1E45 1E46:1E47 1E48:1E49
        1E4A:1E4B 1E4C:1E4D 1E4E:1E4F 1E50:1E51 1E52:1E53 1E54:1E55 1E56:1E57 1E58:1E59 1E5A:1E5B 1E5C:1E5D 1E5E:1E5F
        1E60:1E61 1E62:1E63 1E64:1E65 1E66:1E67 1E68:1E69 1E6A:1E6B 1E6C:1E6D 1E6E:1E6F 1E70:1E71 1E72:1E73 1E74:1E75
        1E76:1E77 1E78:1E79 1E7A:1E7B 1E7C:1E7D 1E7E:1E7F 1E80:1E81 1E82:1E83 1E84:1E85 1E86:1E87 1E88:1E89 1E8A:1E8B
        1E8C:1E8D 1E8E:1E8F 1E90:1E91 1E92:1E93 1E94:1E95 1E96:68,331 1E97:74,308 1E98:77,30A 1E99:79,30A 1E9A:61,2BE
        1E9B:1E61 1E9E:73,73 1EA0:1EA1 1EA2:1EA3 1EA4:1EA5 1EA6:1EA7 1EA8:1EA9 1EAA:1EAB 1EAC:1EAD 1EAE:1EAF 1EB0:1EB1
        1EB2:1EB3 1EB4:1EB5 1EB6:1EB7 1EB8:1EB9 1EBA:1EBB 1EBC:1EBD 1EBE:1EBF 1EC0:1EC1 1EC2:1EC3 1EC4:1EC5 1EC6:1EC7
        1EC8:1EC9 1ECA:1ECB 1ECC:1ECD 1ECE:1ECF 1ED0:1ED1 1ED2:1ED3 1ED4:1ED5 1ED6:1ED7 1ED8:1ED9 1EDA:1EDB 1EDC:1EDD
        1EDE:1EDF 1EE0:1EE1 1EE2:1EE3 1EE4:1EE5 1EE6:1EE7 1EE8:1EE9 1EEA:1EEB 1EEC:1EED 1EEE:1EEF 1EF0:1EF1 1EF2:1EF3
        1EF4:1EF5 1EF6:1EF7 1EF8:1EF9 1EFA:1EFB 1EFC:1EFD 1EFE:1EFF 1F08:1F00 1F09:1F01 1F0A:1F02 1F0B:1F03 1F0C:1F04
        1F0D:1F05 1F0E:1F06 1F0F:1F07 1F18:1F10 1F19:1F11 1F1A:1F12 1F1B:1F13 1F1C:1F14 1F1D:1F15 1F28:1F20 1F29:1F21
        1F2A:1F22 1F2B:1F23 1F2C:1F24 1F2D:1F25 1F2E:1F26 1F2F:1F27 1F38:1F30 1F39:1F31 1F3A:1F32 1F3B:1F33 1F3C:1F34
        1F3D:1F35 1F3E:1F36 1F3F:1F37 1F48:1F40 1F49:1F41 1F4A:1F42 1F4B:1F43 1F4C:1F44 1F4D:1F45 1F50:3C5,313
        1F52:3C5,313,300 1F54:3C5,313,301 1F56:3C5,313,342 1F59:1F51 1F5B:1F53 1F5D:1F55 1F5F:1F57 1F68:1F60 1F69:1F61
        1F6A:1F62 1F6B:1F63 1F6C:1F64 1F6D:1F65 1F6E:1F66 1F6F:1F67 1F80:1F00,3B9 1F81:1F01,3B9 1F82:1F02,3B9
        1F83:1F03,3B9 1F84:1F04,3B9 1F85:1F05,3B9 1F86:1F06,3B9 1F87:1F07,3B9 1F88:1F00,3B9 1F89:1F01,3B9 1F8A:1F02,3B9
        1F8B:1F03,3B9 1F8C:1F04,3B9 1F8D:1F05,3B9 1F8E:1F06,3B9 1F8F:1F07,3B9 1F90:1F20,3B9 1F91:1F21,3B9 1F92:1F22,3B9
        1F93:1F23,3B9 1F94:1F24,3B9 1F95:1F25,3B9 1F96:1F26,3B9 1F97:1F27,3B9 1F98:1F20,3B9 1F99:1F21,3B9 1F9A:1F22,3B9
        1F9B:1F23,3B9 1F9C:1F24,3B9 1F9D:1F25,3B9 1F9E:1F26,3B9 1F9F:1F27,3B9 1FA0:1F60,3B9 1FA1:1F61,3B9 1FA2:1F62,3B9
        1FA3:1F63,3B9 1FA4:1F64,3B9 1FA5:1F65,3B9 1FA6:1F66,3B9 1FA7:1F67,3B9 1FA8:1F60,3B9 1FA9:1F61,3B9 1FAA:1F62,3B9
        1FAB:1F63,3B9 1FAC:1F64,3B9 1FAD:1F65,3B9 1FAE:1F66,3B9 1FAF:1F67,3B9 1FB2:1F70,3B9 1FB3:3B1,3B9 1FB4:3AC,3B9
        1FB6:3B1,342 1FB7:3B1,342,3B9 1FB8:1FB0 1FB9:1FB1 1FBA:1F70 1FBB:1F71 1FBC:3B1,3B9 1FBE:3B9 1FC2:1F74,3B9
        1FC3:3B7,3B9 1FC4:3AE,3B9 1FC6:3B7,342 1FC7:3B7,342,3B9 1FC8:1F72 1FC9:1F73 1FCA:1F74 1FCB:1F75 1FCC:3B7,3B9
        1FD2:3B9,308,300 1FD3:3B9,308,301 1FD6:3B9,342 1FD7:3B9,308,342 1FD8:1FD0 1FD9:1FD1 1FDA:1F76 1FDB:1F77
        1FE2:3C5,308,300 1FE3:3C5,308,301 1FE4:3C1,313 1FE6:3C5,342 1FE7:3C5,308,342 1FE8:1FE0 1FE9:1FE1 1FEA:1F7A
        1FEB:1F7B 1FEC:1FE5 1FF2:1F7C,3B9 1FF3:3C9,3B9 1FF4:3CE,3B9 1FF6:3C9,342 1FF7:3C9,342,3B9 1FF8:1F78 1FF9:1F79
        1FFA:1F7C 1FFB:1F7D 1FFC:3C9,3B9 2126:3C9 212A:6B 212B:E5 2132:214E 2160:2170 2161:2171 2162:2172 2163:2173
        2164:2174 2165:2175 2166:2176 2167:2177 2168:2178 2169:2179 216A:217A 216B:217B 216C:217C 216D:217D 216E:217E
        216F:217F 2183:2184 24B6:24D0 24B7:24D1 24B8:24D2 24B9:24D3 24BA:24D4 24BB:24D5 24BC:24D6 24BD:24D7 24BE:24D8
        24BF:24D9 24C0:24DA 24C1:24DB 24C2:24DC 24C3:24DD 24C4:24DE 24C5:24DF 24C6:24E0 24C7:24E1 24C8:24E2 24C9:24E3
        24CA:24E4 24CB:24E5 24CC:24E6 24CD:24E7 24CE:24E8 24CF:24E9 2C00:2C30 2C01:2C31 2C02:2C32 2C03:2C33 2C04:2C34
        2C05:2C35 2C06:2C36 2C07:2C37 2C08:2C38 2C09:2C39 2C0A:2C3A 2C0B:2C3B 2C0C:2C3C 2C0D:2C3D 2C0E:2C3E 2C0F:2C3F
        2C10:2C40 2C11:2C41 2C12:2C42 2C13:2C43 2C14:2C44 2C15:2C45 2C16:2C46 2C17:2C47 2C18:2C48 2C19:2C49 2C1A:2C4A
        2C1B:2C4B 2C1C:2C4C 2C1D:2C4D 2C1E:2C4E 2C1F:2C4F 2C20:2C50 2C21:2C51 2C22:2C52 2C23:2C53 2C24:2C54 2C25:2C55
        2C26:2C56 2C27:2C57 2C28:2C58 2C29:2C59 2C2A:2C5A 2C2B:2C5B 2C2C:2C5C 2C2D:2C5D 2C2E:2C5E 2C2F:2C5F 2C60:2C61
        2C62:26B 2C63:1D7D 2C64:27D 2C67:2C68 2C69:2C6A 2C6B:2C6C 2C6D:251 2C6E:271 2C6F:250 2C70:252 2C72:2C73
        2C75:2C76 2C7E:23F 2C7F:240 2C80:2C81 2C82:2C83 2C84:2C85 2C86:2C87 2C88:2C89 2C8A:2C8B 2C8C:2C8D 2C8E:2C8F
        2C90:2C91 2C92:2C93 2C94:2C95 2C96:2C97 2C98:2C99 2C9A:2C9B 2C9C:2C9D 2C9E:2C9F 2CA0:2CA1 2CA2:2CA3 2CA4:2CA5
        2CA6:2CA7 2CA8:2CA9 2CAA:2CAB 2CAC:2CAD 2CAE:2CAF 2CB0:2CB1 2CB2:2CB3 2CB4:2CB5 2CB6:2CB7 2CB8:2CB9 2CBA:2CBB
        2CBC:2CBD 2CBE:2CBF 2CC0:2CC1 2CC2:2CC3 2CC4:2CC5 2CC6:2CC7 2CC8:2CC9 2CCA:2CCB 2CCC:2CCD 2CCE:2CCF 2CD0:2CD1
        2CD2:2CD3 2CD4:2CD5 2CD6:2CD7 2CD8:2CD9 2CDA:2CDB 2CDC:2CDD 2CDE:2CDF 2CE0:2CE1 2CE2:2CE3 2CEB:2CEC 2CED:2CEE
        2CF2:2CF3 A640:A641 A642:A643 A644:A645 A646:A647 A648:A649 A64A:A64B A64C:A64D A64E:A64F A650:A651 A652:A653
        A654:A655 A656:A657 A658:A659 A65A:A65B A65C:A65D A65E:A65F A660:A661 A662:A663 A664:A665 A666:A667 A668:A669
        A66A:A66B A66C:A66D A680:A681 A682:A683 A684:A685 A686:A687 A688:A689 A68A:A68B A68C:A68D A68E:A68F A690:A691
        A692:A693 A694:A695 A696:A697 A698:A699 A69A:A69B A722:A723 A724:A725 A726:A727 A728:A729 A72A:A72B A72C:A72D
        A72E:A72F A732:A733 A734:A735 A736:A737 A738:A739 A73A:A73B A73C:A73D A73E:A73F A740:A741 A742:A743 A744:A745
        A746:A747 A748:A749 A74A:A74B A74C:A74D A74E:A74F A750:A751 A752:A753 A754:A755 A756:A757 A758:A759 A75A:A75B
        A75C:A75D A75E:A75F A760:A761 A762:A763 A764:A765 A766:A767 A768:A769 A76A:A76B A76C:A76D A76E:A76F A779:A77A
        A77B:A77C A77D:1D79 A77E:A77F A780:A781 A782:A783 A784:A785 A786:A787 A78B:A78C A78D:265 A790:A791 A792:A793
        A796:A797 A798:A799 A79A:A79B A79C:A79D A79E:A79F A7A0:A7A1 A7A2:A7A3 A7A4:A7A5 A7A6:A7A7 A7A8:A7A9 A7AA:266
        A7AB:25C A7AC:261 A7AD:26C A7AE:26A A7B0:29E A7B1:287 A7B2:29D A7B3:AB53 A7B4:A7B5 A7B6:A7B7 A7B8:A7B9
        A7BA:A7BB A7BC:A7BD A7BE:A7BF A7C0:A7C1 A7C2:A7C3 A7C4:A794 A7C5:282 A7C6:1D8E A7C7:A7C8 A7C9:A7CA
        A7D0:A7D1 A7D6:A7D7 A7D8:A7D9 A7F5:A7F6 AB70:13A0 AB71:13A1 AB72:13A2 AB73:13A3
        AB74:13A4 AB75:13A5 AB76:13A6 AB77:13A7 AB78:13A8 AB79:13A9 AB7A:13AA AB7B:13AB AB7C:13AC AB7D:13AD AB7E:13AE
        AB7F:13AF AB80:13B0 AB81:13B1 AB82:13B2 AB83:13B3 AB84:13B4 AB85:13B5 AB86:13B6 AB87:13B7 AB88:13B8 AB89:13B9
        AB8A:13BA AB8B:13BB AB8C:13BC AB8D:13BD AB8E:13BE AB8F:13BF AB90:13C0 AB91:13C1 AB92:13C2 AB93:13C3 AB94:13C4
        AB95:13C5 AB96:13C6 AB97:13C7 AB98:13C8 AB99:13C9 AB9A:13CA AB9B:13CB AB9C:13CC AB9D:13CD AB9E:13CE AB9F:13CF
        ABA0:13D0 ABA1:13D1 ABA2:13D2 ABA3:13D3 ABA4:13D4 ABA5:13D5 ABA6:13D6 ABA7:13D7 ABA8:13D8 ABA9:13D9 ABAA:13DA
        ABAB:13DB ABAC:13DC ABAD:13DD ABAE:13DE ABAF:13DF ABB0:13E0 ABB1:13E1 ABB2:13E2 ABB3:13E3 ABB4:13E4 ABB5:13E5
        ABB6:13E6 ABB7:13E7 ABB8:13E8 ABB9:13E9 ABBA:13EA ABBB:13EB ABBC:13EC ABBD:13ED ABBE:13EE ABBF:13EF FB00:66,66
        FB01:66,69 FB02:66,6C FB03:66,66,69 FB04:66,66,6C FB05:73,74 FB06:73,74 FB13:574,576 FB14:574,565 FB15:574,56B
        FB16:57E,576 FB17:574,56D FF21:FF41 FF22:FF42 FF23:FF43 FF24:FF44 FF25:FF45 FF26:FF46 FF27:FF47 FF28:FF48
        FF29:FF49 FF2A:FF4A FF2B:FF4B FF2C:FF4C FF2D:FF4D FF2E:FF4E FF2F:FF4F FF30:FF50 FF31:FF51 FF32:FF52 FF33:FF53
        FF34:FF54 FF35:FF55 FF36:FF56 FF37:FF57 FF38:FF58 FF39:FF59 FF3A:FF5A 10400:10428 10401:10429 10402:1042A
        10403:1042B 10404:1042C 10405:1042D 10406:1042E 10407:1042F 10408:10430 10409:10431 1040A:10432 1040B:10433
        1040C:10434 1040D:10435 1040E:10436 1040F:10437 10410:10438 10411:10439 10412:1043A 10413:1043B 10414:1043C
        10415:1043D 10416:1043E 10417:1043F 10418:10440 10419:10441 1041A:10442 1041B:10443 1041C:10444 1041D:10445
        1041E:10446 1041F:10447 10420:10448 10421:10449 10422:1044A 10423:1044B 10424:1044C 10425:1044D 10426:1044E
        10427:1044F 104B0:104D8 104B1:104D9 104B2:104DA 104B3:104DB 104B4:104DC 104B5:104DD 104B6:104DE 104B7:104DF
        104B8:104E0 104B9:104E1 104BA:104E2 104BB:104E3 104BC:104E4 104BD:104E5 104BE:104E6 104BF:104E7 104C0:104E8
        104C1:104E9 104C2:104EA 104C3:104EB 104C4:104EC 104C5:104ED 104C6:104EE 104C7:104EF 104C8:104F0 104C9:104F1
        104CA:104F2 104CB:104F3 104CC:104F4 104CD:104F5 104CE:104F6 104CF:104F7 104D0:104F8 104D1:104F9 104D2:104FA
        104D3:104FB 10570:10597 10571:10598 10572:10599 10573:1059A 10574:1059B 10575:1059C 10576:1059D 10577:1059E
        10578:1059F 10579:105A0 1057A:105A1 1057C:105A3 1057D:105A4 1057E:105A5 1057F:105A6 10580:105A7 10581:105A8
        10582:105A9 10583:105AA 10584:105AB 10585:105AC 10586:105AD 10587:105AE 10588:105AF 10589:105B0 1058A:105B1
        1058C:105B3 1058D:105B4 1058E:105B5 1058F:105B6 10590:105B7 10591:105B8 10592:105B9 10594:105BB 10595:105BC
        10C80:10CC0 10C81:10CC1 10C82:10CC2 10C83:10CC3 10C84:10CC4 10C85:10CC5 10C86:10CC6 10C87:10CC7 10C88:10CC8
        10C89:10CC9 10C8A:10CCA 10C8B:10CCB 10C8C:10CCC 10C8D:10CCD 10C8E:10CCE 10C8F:10CCF 10C90:10CD0 10C91:10CD1
        10C92:10CD2 10C93:10CD3 10C94:10CD4 10C95:10CD5 10C96:10CD6 10C97:10CD7 10C98:10CD8 10C99:10CD9 10C9A:10CDA
        10C9B:10CDB 10C9C:10CDC 10C9D:10CDD 10C9E:10CDE 10C9F:10CDF 10CA0:10CE0 10CA1:10CE1 10CA2:10CE2 10CA3:10CE3
        10CA4:10CE4 10CA5:10CE5 10CA6:10CE6 10CA7:10CE7 10CA8:10CE8 10CA9:10CE9 10CAA:10CEA 10CAB:10CEB 10CAC:10CEC
        10CAD:10CED 10CAE:10CEE 10CAF:10CEF 10CB0:10CF0 10CB1:10CF1 10CB2:10CF2
        118A0:118C0 118A1:118C1 118A2:118C2 118A3:118C3 118A4:118C4 118A5:118C5 118A6:118C6 118A7:118C7
        118A8:118C8 118A9:118C9 118AA:118CA 118AB:118CB 118AC:118CC 118AD:118CD 118AE:118CE 118AF:118CF 118B0:118D0
        118B1:118D1 118B2:118D2 118B3:118D3 118B4:118D4 118B5:118D5 118B6:118D6 118B7:118D7 118B8:118D8 118B9:118D9
        118BA:118DA 118BB:118DB 118BC:118DC 118BD:118DD 118BE:118DE 118BF:118DF 16E40:16E60 16E41:16E61 16E42:16E62
        16E43:16E63 16E44:16E64 16E45:16E65 16E46:16E66 16E47:16E67 16E48:16E68 16E49:16E69 16E4A:16E6A 16E4B:16E6B
        16E4C:16E6C 16E4D:16E6D 16E4E:16E6E 16E4F:16E6F 16E50:16E70 16E51:16E71 16E52:16E72 16E53:16E73 16E54:16E74
        16E55:16E75 16E56:16E76 16E57:16E77 16E58:16E78 16E59:16E79 16E5A:16E7A 16E5B:16E7B 16E5C:16E7C 16E5D:16E7D
        16E5E:16E7E 16E5F:16E7F 1E900:1E922 1E901:1E923 1E902:1E924 1E903:1E925 1E904:1E926 1E905:1E927 1E906:1E928
        1E907:1E929 1E908:1E92A 1E909:1E92B 1E90A:1E92C 1E90B:1E92D 1E90C:1E92E 1E90D:1E92F 1E90E:1E930 1E90F:1E931
        1E910:1E932 1E911:1E933 1E912:1E934 1E913:1E935 1E914:1E936 1E915:1E937 1E916:1E938 1E917:1E939 1E918:1E93A
        1E919:1E93B 1E91A:1E93C 1E91B:1E93D 1E91C:1E93E 1E91D:1E93F 1E91E:1E940 1E91F:1E941 1E920:1E942 1E921:1E943
        """
}

struct LocalAnimalIdentityError: LocalizedError, Equatable {
    let field = "animalId"

    func message(language: AppLanguage) -> String {
        language == .russian
            ? "Не удалось сохранить ID животного: он уже используется другой локальной карточкой, включая историю и другие аккаунты данных. Выберите существующую собаку или исправьте ID. Если карточка не видна, проверьте аккаунт данных и восстановите анкеты. Черновик и записи сохранены; автоматического объединения нет."
            : "Cannot save animal ID: another local dog already uses it, including historical profiles and other data accounts. Select the existing dog or correct the ID. If it is not visible, check the data account and restore profiles. Your draft and recordings are preserved; no profiles are merged automatically."
    }
    var errorDescription: String? { message(language: .english) }
}

enum ProfileIdentityStatus: String, Equatable {
    case unverified, checking, serverConfirmed, conflict, offline, needsAttention
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

struct RetirementCleanupStatus: Equatable, Sendable {
    var pendingCount: Int
    var lastError: String?
    var deferredCount: Int = 0
}

struct CaptureFinalizationResult: Sendable {
    var retired: Bool
    var cleanupError: String?
}

struct CaptureStoppedTiming: Sendable {
    let endedAt: Date
    let durationSeconds: Double?

    init(endedAt: Date, startedMonotonicNs: UInt64?, stoppedMonotonicNs: UInt64) {
        self.endedAt = endedAt
        durationSeconds = startedMonotonicNs.flatMap { start in
            stoppedMonotonicNs >= start ? Double(stoppedMonotonicNs - start) / 1_000_000_000 : nil
        }
    }
}

enum CaptureFinalizer {
    @discardableResult
    static func run(root: URL, recordingID: UUID, status: String,
                    files: [(type: String, source: URL, name: String, mime: String)], syncJSON: Data,
                    timing: CaptureStoppedTiming? = nil,
                    onWorkerStart: (@Sendable () -> Void)? = nil) async throws -> CaptureFinalizationResult {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            onWorkerStart?()
            let store = try WoonaStore(rootDirectory: root)
            guard let recording = try store.recording(id: recordingID) else {
                throw WoonaStoreError.invalidData("Capture disappeared before local finalization")
            }
            try store.finalize(recording: recording, status: status, files: files, syncJSON: syncJSON, timing: timing)
            var cleanupError: String?
            do { _ = try store.applyDeferredServerDeletions() }
            catch { cleanupError = error.localizedDescription }
            do { return CaptureFinalizationResult(retired: try store.recording(id: recordingID) == nil, cleanupError: cleanupError) }
            catch { return CaptureFinalizationResult(retired: false, cleanupError: error.localizedDescription) }
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
}

struct RecordingHistoryCursor: Sendable {
    let sortMillis: Int64
    let id: UUID
    let rowIDWatermark: Int64
}

struct RecordingHistoryFiles: Sendable {
    var local = 0
    var total = 0
    var uploadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var verified = 0
    var needsDownload = false
}

// The snapshot contains copied value models only. SQLite handles remain on their
// owning worker and never cross to MainActor.
struct RecordingHistorySnapshot: @unchecked Sendable {
    let recordings: [WoonaRecording]
    let totalCount: Int
    let cursor: RecordingHistoryCursor?
    let hasMore: Bool
    let files: [UUID: RecordingHistoryFiles]
    let syncErrors: [UUID: String]
    let cleanup: RetirementCleanupStatus
    let queue: (pending: Int, uploading: Int, synced: Int, failed: Int, lastError: String?)
}

final class WoonaStore {
    private var database: OpaquePointer?
#if DEBUG
    private(set) var queryCountForTesting = 0
#endif
    let rootDirectory: URL

    init(rootDirectory: URL? = nil, readOnly: Bool = false) throws {
        let base = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Woona", isDirectory: true)
        self.rootDirectory = base
        if !readOnly { try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true) }
        // Readers need a lock-capable descriptor beside the app's writer on
        // Darwin. Enforce read-only SQL with query_only; never CREATE a missing
        // database or run migrations for a reader connection.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (readOnly ? 0 : SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(base.appendingPathComponent("woona.sqlite").path, &database, flags, nil) == SQLITE_OK else {
            throw WoonaStoreError.sqlite("Unable to open woona.sqlite")
        }
        try execute("PRAGMA foreign_keys=ON")
        sqlite3_busy_timeout(database, 5_000)
        if readOnly { try execute("PRAGMA query_only=ON") }
        else { try migrate() }
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
        // Run before even the unchanged-edit fast path: historical identities
        // are globally reserved across account scopes, but never against self.
        try validateLocalAnimalIdentity(questionnaire.animalId, excluding: profile?.id)
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
            try validateLocalAnimalIdentity(questionnaire.animalId, excluding: profile?.id)
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
            try updateProfileSync(versionID: versionID, state: "pending")
        }
        return try profiles().first { $0.id == dogID }!
    }

    private func validateLocalAnimalIdentity(_ animalID: String?, excluding dogID: UUID?) throws {
        guard let animalID else { return }
        let key = AnimalIdentityKey.bytes(animalID)
        guard !key.isEmpty else { return }
        // No scope filter and no current-version join: old versions reserve IDs.
        let statement = try prepare("SELECT dog_id,questionnaire_json FROM dog_profile_versions")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let dogID, UUID(uuidString: columnText(statement, 0)) == dogID { continue }
            let questionnaire = try JSONDecoder().decode(DogQuestionnaire.self, from: Data(columnText(statement, 1).utf8))
            if let existing = questionnaire.animalId, AnimalIdentityKey.bytes(existing) == key {
                throw LocalAnimalIdentityError()
            }
        }
    }

    func linkDog(dogID: UUID, accountID: String) throws {
        guard let dog = try profiles().first(where: { $0.id == dogID }), dog.accountID == nil || dog.accountID == accountID else {
            throw WoonaStoreError.invalidData("Dog already belongs to another account")
        }
        if dog.accountID == accountID { return }
        try transaction {
            try execute("UPDATE dogs SET account_id=? WHERE id=?", [.text(accountID), .text(dogID.uuidString)])
            // A receipt for the unassigned scope does not confirm this scope.
            try updateProfileSync(versionID: dog.profileVersionID, state: "pending")
        }
    }

    // Acceptance belongs to a version UUID; a dog's revision cannot confirm a new version.
    func pendingProfiles() throws -> [DogProfile] {
        try profiles().filter { ["pending", "retryable_error"].contains(try profileSyncState(versionID: $0.profileVersionID)) }
    }

    func profileSyncState(versionID: UUID) throws -> String {
        let statement = try prepare("SELECT state FROM profile_sync_state WHERE profile_version_id=?", [.text(versionID.uuidString)])
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? columnText(statement, 0) : "pending"
    }

    func profileSyncDetails(versionID: UUID) throws -> (state: String, error: String?, updatedAt: String?) {
        let statement = try prepare("SELECT state,last_error,updated_at_utc FROM profile_sync_state WHERE profile_version_id=?", [.text(versionID.uuidString)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return ("pending", nil, nil) }
        return (columnText(statement, 0), columnOptionalText(statement, 1), columnOptionalText(statement, 2))
    }

    func profileSyncOverview() throws -> (pending: Int, failed: Int, lastError: String?) {
        let statement = try prepare("""
            SELECT SUM(CASE WHEN s.state IN ('pending','retryable_error') THEN 1 ELSE 0 END),
                   SUM(CASE WHEN s.state IN ('retryable_error','permanent_error') THEN 1 ELSE 0 END),
                   (SELECT last_error FROM profile_sync_state e JOIN dogs ed ON ed.current_profile_version_id=e.profile_version_id
                    WHERE e.last_error IS NOT NULL ORDER BY e.updated_at_utc DESC LIMIT 1)
            FROM profile_sync_state s JOIN dogs d ON d.current_profile_version_id=s.profile_version_id
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0, nil) }
        return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)), columnOptionalText(statement, 2))
    }

    func updateProfileSync(versionID: UUID, state: String, error: Error? = nil) throws {
        guard ["pending", "retryable_error", "permanent_error", "synced"].contains(state) else { throw WoonaStoreError.invalidData("Invalid profile sync state") }
        try execute("""
            INSERT INTO profile_sync_state(profile_version_id,state,last_error,updated_at_utc) VALUES(?,?,?,?)
            ON CONFLICT(profile_version_id) DO UPDATE SET state=excluded.state,last_error=excluded.last_error,updated_at_utc=excluded.updated_at_utc
            """, [.text(versionID.uuidString), .text(state), error.map { .text(safeSyncDiagnostic($0.localizedDescription)) } ?? .null, .text(Self.iso8601(Date()))])
    }

    func markProfileAccepted(dogID: UUID, versionID: UUID) throws {
        guard let version = try existingProfileVersion(id: versionID) else { return }
        guard version.dogID == dogID else { throw WoonaStoreError.invalidData("Acknowledged profile belongs to another dog") }
        try updateProfileSync(versionID: versionID, state: "synced")
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
        let preserveLocal = try existing.map {
            let unacknowledged = try profileSyncState(versionID: $0.profileVersionID) != "synced"
            return $0.profileVersionID != profileVersionID && (unacknowledged || $0.revision == 0 || $0.revision >= revision)
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
        try markProfileAccepted(dogID: dogID, versionID: profileVersionID)
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
            try markProfileAccepted(dogID: dogID, versionID: version.id)
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
        try markProfileAccepted(dogID: dogID, versionID: version.id)
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
        try markProfileAccepted(dogID: remote.dogId, versionID: remote.profileVersion.id)
        return !didExist
    }

    // Preparation creates the row/directory; Start supplies the actual acquisition
    // wall anchor before immutable manifests exist. Recovery never calls this.
    func markCaptureStarted(_ id: UUID, at date: Date) throws {
        guard let recording = try recording(id: id), recording.status == "preparing" else {
            throw WoonaStoreError.invalidData("Capture is not preparing")
        }
        var questionnaire = recording.questionnaire
        if questionnaire?.schemaVersion == 2 && recording.source == "live" {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: recording.timezone)
            formatter.dateFormat = "yyyy-MM-dd"
            questionnaire?.sessionDate = formatter.string(from: date)
            formatter.dateFormat = "HH:mm"
            questionnaire?.startTime = formatter.string(from: date)
            questionnaire?.endTime = nil
            questionnaire?.durationMinutes = nil
        }
        let json = try questionnaire.map { String(decoding: try Self.sessionQuestionnaireData($0), as: UTF8.self) }
        try execute("UPDATE recordings SET status='recording',started_at_utc=?,questionnaire_json=COALESCE(?,questionnaire_json) WHERE id=?",
                    [.text(Self.iso8601(date)), json.map { .text($0) } ?? .null, .text(id.uuidString)])
    }

    func markRecording(_ id: UUID, status: String, endedAt: Date? = nil) throws {
        try execute(
            "UPDATE recordings SET status=?,ended_at_utc=COALESCE(?,ended_at_utc) WHERE id=?",
            [.text(status), endedAt.map { .text(Self.iso8601($0)) } ?? .null, .text(id.uuidString)]
        )
    }

    func saveSessionQuestionnaire(recordingID: UUID, questionnaire: SessionQuestionnaire, revision: Int? = nil) throws {
        guard let recording = try recording(id: recordingID), ["completed", "failed", "interrupted"].contains(recording.status),
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
        guard heart.validate().isValid, let recording = try recording(id: recordingID), ["completed", "failed", "interrupted"].contains(recording.status),
              var questionnaire = recording.questionnaire, questionnaire.sessionKind == "heart" else {
            throw WoonaStoreError.invalidData("Анкета не заполнена или запись ещё не завершена")
        }
        questionnaire.heartQuestionnaire = heart.normalized()
        try saveSessionQuestionnaire(recordingID: recordingID, questionnaire: questionnaire)
    }

    func attachReference(recordingID: UUID, type: String, sourceURL: URL, metadata: ReferenceMetadata) throws {
        guard ["ecg", "heart_rate", "rr"].contains(type), metadata.validate().isValid,
              let recording = try recording(id: recordingID), ["completed", "failed", "interrupted"].contains(recording.status), recording.serverSyncState != "remote" else {
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

    private static func historySortSQL(_ column: String = "started_at_utc") -> String {
        "COALESCE(CAST(ROUND((CASE WHEN \(column) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*' THEN julianday(\(column)) END-2440587.5)*86400000.0) AS INTEGER),-9223372036854775807)"
    }

    func recentRecordings(dogID: UUID, limit: Int? = 10, after: RecordingHistoryCursor? = nil, rowIDWatermark: Int64? = nil) throws -> [WoonaRecording] {
        let sort = Self.historySortSQL("r.started_at_utc")
        let cursorFilter = after == nil ? "" : " AND (\(sort),r.id)<(?,?)"
        let watermark = after?.rowIDWatermark ?? rowIDWatermark
        let watermarkFilter = watermark == nil ? "" : " AND r.rowid<=?"
        var arguments: [SQLiteValue] = [.text(dogID.uuidString)]
        if let after { arguments += [.integer(after.sortMillis), .text(after.id.uuidString)] }
        if let watermark { arguments.append(.integer(watermark)) }
        arguments.append(.integer(Int64(limit.map { max($0, 0) } ?? -1)))
        let statement = try prepare(
            """
            SELECT r.id,r.dog_id,r.dog_profile_version_id,r.source,r.status,r.session_label,
                   r.video_requested,r.started_at_utc,r.ended_at_utc,r.timezone,
                   r.questionnaire_json,r.relative_directory,r.server_sync_state,r.app_version,r.questionnaire_revision,r.questionnaire_dirty,
                   clock.sync_json,COALESCE(state.last_error_code,'')
            FROM recordings r
            LEFT JOIN recording_sync clock ON clock.recording_id=r.id
            LEFT JOIN server_sync_state state ON state.recording_id=r.id
            WHERE r.dog_id=?\(cursorFilter)\(watermarkFilter) ORDER BY \(sort) DESC,r.id DESC LIMIT ?
            """,
            arguments
        )
        defer { sqlite3_finalize(statement) }
        var result: [WoonaRecording] = []
        while true {
                    let step = sqlite3_step(statement)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW else { throw sqliteError() }
            try Task.checkCancellation()
            let sync = columnOptionalText(statement, 16).map { Data($0.utf8) }
            result.append(try decodeRecording(statement, syncData: sync, needsRecoveryReview: columnText(statement, 17) == "capture_recovery_requires_review"))
        }
        return result
    }

    func recordingHistorySnapshot(dogID: UUID, limit: Int, after: RecordingHistoryCursor? = nil, knownTotalCount: Int? = nil) throws -> RecordingHistorySnapshot {
        // One read transaction keeps record rows, queue messages and artifact
        // progress consistent. Bound IN lists below Apple's older SQLite limits.
        try execute("BEGIN")
        do {
            try Task.checkCancellation()
            let watermark: Int64
            if let after { watermark = after.rowIDWatermark }
            else {
                let statement = try prepare("SELECT COALESCE(MAX(rowid),0) FROM recordings")
                guard sqlite3_step(statement) == SQLITE_ROW else { let error = sqliteError(); sqlite3_finalize(statement); throw error }
                watermark = sqlite3_column_int64(statement, 0); sqlite3_finalize(statement)
            }
            let fetched = try recentRecordings(dogID: dogID, limit: max(0, limit) + 1, after: after, rowIDWatermark: watermark)
            let rows = Array(fetched.prefix(max(0, limit)))
            var cursor: RecordingHistoryCursor?
            if let last = rows.last {
                let key = try prepare("SELECT \(Self.historySortSQL()) FROM recordings WHERE id=?", [.text(last.id.uuidString)])
                if sqlite3_step(key) == SQLITE_ROW { cursor = RecordingHistoryCursor(sortMillis: sqlite3_column_int64(key, 0), id: last.id, rowIDWatermark: watermark) }
                sqlite3_finalize(key)
            }
            let total: Int
            if let knownTotalCount { total = knownTotalCount }
            else {
                let totalStatement = try prepare("SELECT COUNT(*) FROM recordings WHERE dog_id=? AND rowid<=?", [.text(dogID.uuidString), .integer(watermark)])
                guard sqlite3_step(totalStatement) == SQLITE_ROW else {
                    let error = sqliteError(); sqlite3_finalize(totalStatement); throw error
                }
                total = Int(sqlite3_column_int64(totalStatement, 0))
                sqlite3_finalize(totalStatement)
            }
            let ids = rows.map(\.id)
            var files: [UUID: RecordingHistoryFiles] = Dictionary(uniqueKeysWithValues: ids.map { ($0, RecordingHistoryFiles()) })
            var errors: [UUID: String] = [:]
            for start in stride(from: 0, to: ids.count, by: 500) {
                try Task.checkCancellation()
                let page = Array(ids[start..<min(start + 500, ids.count)])
                let placeholders = Array(repeating: "?", count: page.count).joined(separator: ",")
                let values = page.map { SQLiteValue.text($0.uuidString) }
                let artifacts = try prepare("SELECT recording_id,relative_path,size_bytes,uploaded_bytes,upload_state FROM artifacts WHERE recording_id IN (\(placeholders))", values)
                defer { sqlite3_finalize(artifacts) }
                while true {
                    let step = sqlite3_step(artifacts)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW else { throw sqliteError() }
                    try Task.checkCancellation()
                    guard let id = UUID(uuidString: columnText(artifacts, 0)) else { throw WoonaStoreError.invalidData("Invalid history artifact recording ID") }
                    var summary = files[id] ?? RecordingHistoryFiles()
                    let exists = FileManager.default.fileExists(atPath: rootDirectory.appendingPathComponent(columnText(artifacts, 1)).path)
                    let size = max(0, sqlite3_column_int64(artifacts, 2))
                    summary.total += 1; summary.local += exists ? 1 : 0
                    summary.totalBytes += size; summary.uploadedBytes += min(max(0, sqlite3_column_int64(artifacts, 3)), size)
                    if columnText(artifacts, 4) == "available" { summary.verified += 1; summary.needsDownload = summary.needsDownload || !exists }
                    files[id] = summary
                }
                let state = try prepare("SELECT recording_id,COALESCE(NULLIF(last_error_message,''),last_error_code) FROM server_sync_state WHERE state IN ('retryable_error','permanent_error') AND recording_id IN (\(placeholders))", values)
                defer { sqlite3_finalize(state) }
                while true {
                    let step = sqlite3_step(state)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW else { throw sqliteError() }
                    try Task.checkCancellation()
                    if let id = UUID(uuidString: columnText(state, 0)), let error = columnOptionalText(state, 1) { errors[id] = error }
                }
            }
            let snapshot = RecordingHistorySnapshot(recordings: rows, totalCount: total, cursor: cursor, hasMore: fetched.count > rows.count, files: files, syncErrors: errors, cleanup: try retirementCleanupStatus(), queue: try syncOverview())
            try execute("COMMIT")
            return snapshot
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func acceptServerProfile(dogID: UUID, version: ServerProfileVersion) throws {
        let json = String(decoding: try Self.dogQuestionnaireData(version.questionnaire), as: UTF8.self)
        try execute("UPDATE dog_profile_versions SET questionnaire_json=?,content_sha256=? WHERE id=? AND dog_id=?",
                    [.text(json), .text(version.contentSha256), .text(version.id.uuidString), .text(dogID.uuidString)])
        try markProfileAccepted(dogID: dogID, versionID: version.id)
    }

    func acceptServerSession(recordingID: UUID, questionnaire: JSONValue) throws {
        let json = String(decoding: try Self.encoder.encode(questionnaire), as: UTF8.self)
        try execute("UPDATE recordings SET questionnaire_json=? WHERE id=?", [.text(json), .text(recordingID.uuidString)])
    }

    @discardableResult
    // Server retirement is global and owner-authorized. accountID remains a
    // compatibility argument; switching workspaces cannot resurrect retired UUIDs.
    func applyServerDeletions(_ entities: [ServerDeletion], accountID _: String? = nil,
                              removeItem: ((URL) throws -> Void)? = nil) throws -> Int {
        let previouslyDeferred = try deferredServerDeletions()
        let accepted = Set(entities + previouslyDeferred)
        func retired(_ kind: String, _ id: String) -> Bool {
            let hash = Self.sha256(Data(id.lowercased().utf8))
            return accepted.contains(ServerDeletion(kind: kind, id_sha256: hash))
        }
        let statement = try prepare("SELECT id,dog_id,status,relative_directory FROM recordings")
        var ids: [String] = []
        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if ["preparing", "recording"].contains(columnText(statement, 2)) { continue }
            if retired("recording", columnText(statement, 0)) || retired("dog", columnText(statement, 1)) {
                ids.append(columnText(statement, 0))
                let relative = columnText(statement, 3)
                do { _ = try localDeletionURL(relative) }
                catch { sqlite3_finalize(statement); throw error }
                paths.append(relative)
            }
        }
        sqlite3_finalize(statement)
        try transaction {
            for path in paths { try enqueueLocalDeletion(relativePath: path, kind: "directory") }
            for id in ids { try execute("DELETE FROM recordings WHERE id=?", [.text(id)]) }
            let artifacts = try prepare("SELECT a.id,a.relative_path,r.dog_id FROM artifacts a JOIN recordings r ON r.id=a.recording_id WHERE r.status NOT IN ('preparing','recording')")
            var deletedArtifacts: [(String,String)] = []
            while sqlite3_step(artifacts) == SQLITE_ROW {
                if retired("artifact",columnText(artifacts,0)) {
                    let relative = columnText(artifacts,1)
                    do { _ = try localDeletionURL(relative) }
                    catch { sqlite3_finalize(artifacts); throw error }
                    deletedArtifacts.append((columnText(artifacts,0),relative))
                }
            }
            sqlite3_finalize(artifacts)
            for (id,path) in deletedArtifacts {
                try enqueueLocalDeletion(relativePath: path, kind: "file")
                try execute("DELETE FROM artifacts WHERE id=?",[.text(id)])
            }
            let current = try prepare("SELECT current_profile_version_id FROM dogs")
            var currentVersions = Set<String>()
            while sqlite3_step(current) == SQLITE_ROW { currentVersions.insert(columnText(current,0)) }
            sqlite3_finalize(current)
            let versions = try prepare("SELECT id,dog_id FROM dog_profile_versions WHERE id NOT IN (SELECT dog_profile_version_id FROM recordings)")
            var deletedVersions: [String] = []
            while sqlite3_step(versions) == SQLITE_ROW {
                if retired("dog", columnText(versions, 1)) || (retired("profile",columnText(versions,0)) && !currentVersions.contains(columnText(versions,0))) { deletedVersions.append(columnText(versions, 0)) }
            }
            sqlite3_finalize(versions)
            for id in deletedVersions { try execute("DELETE FROM dog_profile_versions WHERE id=?", [.text(id)]) }
            let dogs = try prepare("SELECT id FROM dogs WHERE id NOT IN (SELECT dog_id FROM recordings) AND id NOT IN (SELECT dog_id FROM dog_profile_versions)")
            var deletedDogs: [String] = []
            while sqlite3_step(dogs) == SQLITE_ROW { if retired("dog", columnText(dogs, 0)) { deletedDogs.append(columnText(dogs, 0)) } }
            sqlite3_finalize(dogs)
            for id in deletedDogs { try execute("DELETE FROM dogs WHERE id=?", [.text(id)]) }

            // A received retirement survives process death and credential removal
            // while a live capture, current profile or historical reference still
            // prevents safe retirement. Retry it locally after stop/recovery.
            var deferred = Set<ServerDeletion>()
            for (kind, table) in [("dog", "dogs"), ("profile", "dog_profile_versions"), ("recording", "recordings"), ("artifact", "artifacts")] {
                let rows = try prepare("SELECT id FROM \(table)")
                while sqlite3_step(rows) == SQLITE_ROW {
                    let digest = Self.sha256(Data(columnText(rows, 0).lowercased().utf8))
                    let marker = ServerDeletion(kind: kind, id_sha256: digest)
                    if accepted.contains(marker) { deferred.insert(marker) }
                }
                sqlite3_finalize(rows)
            }
            for marker in previouslyDeferred where !deferred.contains(marker) {
                try execute("DELETE FROM deferred_retirements WHERE kind=? AND id_sha256=?", [.text(marker.kind), .text(marker.id_sha256)])
            }
            for marker in deferred {
                try execute("INSERT OR IGNORE INTO deferred_retirements(kind,id_sha256,received_at_utc) VALUES(?,?,?)",
                    [.text(marker.kind), .text(marker.id_sha256), .text(Self.iso8601(Date()))])
            }
        }
        // The durable intent and SQL retirement commit together. Filesystem work
        // happens only afterwards; a failed SQLite transaction removes no bytes.
        _ = try drainLocalDeletionOutbox(removeItem: removeItem)
        return ids.count
    }

    private func deferredServerDeletions() throws -> [ServerDeletion] {
        let query = try prepare("SELECT kind,id_sha256 FROM deferred_retirements")
        defer { sqlite3_finalize(query) }
        var result: [ServerDeletion] = []
        while sqlite3_step(query) == SQLITE_ROW { result.append(ServerDeletion(kind: columnText(query, 0), id_sha256: columnText(query, 1))) }
        return result
    }

    func hasDeferredRetirement(for recording: WoonaRecording) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM deferred_retirements WHERE (kind='recording' AND id_sha256=?) OR (kind='dog' AND id_sha256=?) LIMIT 1", [
            .text(Self.sha256(Data(recording.id.uuidString.lowercased().utf8))),
            .text(Self.sha256(Data(recording.dogID.uuidString.lowercased().utf8))),
        ])
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW || step == SQLITE_DONE else { throw sqliteError() }
        return step == SQLITE_ROW
    }

    @discardableResult
    func applyDeferredServerDeletions() throws -> Int { try applyServerDeletions([]) }

    private func localDeletionURL(_ relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              relativePath.hasPrefix("recordings/"), !relativePath.split(separator: "/").contains("..") else {
            throw WoonaStoreError.invalidData("Invalid retired local path")
        }
        let root = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
        let path = rootDirectory.appendingPathComponent(relativePath).standardizedFileURL
        guard path.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw WoonaStoreError.invalidData("Retired local path escapes the data directory")
        }
        return path
    }

    private func enqueueLocalDeletion(relativePath: String, kind: String) throws {
        _ = try localDeletionURL(relativePath)
        try execute("INSERT OR IGNORE INTO local_deletion_outbox(id,relative_path,entry_kind,created_at_utc) VALUES(?,?,?,?)",
            [.text(UUID().uuidString), .text(relativePath), .text(kind), .text(Self.iso8601(Date()))])
    }

    func retirementCleanupStatus() throws -> RetirementCleanupStatus {
        let count = try prepare("SELECT count(*) FROM local_deletion_outbox")
        guard sqlite3_step(count) == SQLITE_ROW else { sqlite3_finalize(count); throw sqliteError() }
        let pending = Int(sqlite3_column_int64(count, 0)); sqlite3_finalize(count)
        let deferredQuery = try prepare("SELECT count(*) FROM deferred_retirements")
        guard sqlite3_step(deferredQuery) == SQLITE_ROW else { sqlite3_finalize(deferredQuery); throw sqliteError() }
        let deferred = Int(sqlite3_column_int64(deferredQuery, 0)); sqlite3_finalize(deferredQuery)
        let error = try prepare("SELECT last_error FROM local_deletion_outbox WHERE last_error IS NOT NULL ORDER BY created_at_utc DESC LIMIT 1")
        defer { sqlite3_finalize(error) }
        let lastError = sqlite3_step(error) == SQLITE_ROW ? columnText(error, 0) : nil
        return RetirementCleanupStatus(pendingCount: pending, lastError: lastError, deferredCount: deferred)
    }

    @discardableResult
    func drainLocalDeletionOutbox(removeItem: ((URL) throws -> Void)? = nil) throws -> RetirementCleanupStatus {
        let query = try prepare("SELECT id,relative_path FROM local_deletion_outbox ORDER BY created_at_utc,id")
        var entries: [(String, String)] = []
        while sqlite3_step(query) == SQLITE_ROW { entries.append((columnText(query, 0), columnText(query, 1))) }
        sqlite3_finalize(query)
        for (id, relativePath) in entries {
            do {
                let path = try localDeletionURL(relativePath)
                if FileManager.default.fileExists(atPath: path.path) {
                    if let removeItem { try removeItem(path) }
                    else { try FileManager.default.removeItem(at: path) }
                }
                // Missing files also complete an interrupted prior deletion.
                try execute("DELETE FROM local_deletion_outbox WHERE id=?", [.text(id)])
            } catch {
                try execute("UPDATE local_deletion_outbox SET last_error=? WHERE id=?",
                    [.text(error.localizedDescription), .text(id)])
            }
        }
        return try retirementCleanupStatus()
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
        syncJSON: Data,
        timing: CaptureStoppedTiming? = nil
    ) throws {
        let directory = directory(for: recording)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var finalFiles: [(String, URL, String)] = []
        for file in files where FileManager.default.fileExists(atPath: file.source.path) {
            let target = directory.appendingPathComponent(file.name)
            // Different URL spellings can name this same file (/var aliases or symlinks).
            // Resolve before removing a destination, otherwise copying onto itself can
            // delete the only original packet/video file.
            if file.source.resolvingSymlinksInPath().standardizedFileURL != target.resolvingSymlinksInPath().standardizedFileURL {
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
        let endedAt = timing.map { Self.iso8601($0.endedAt) } ?? now
        // Hash closed files outside the write transaction. A large video must
        // not hold SQLite's writer lock while the main actor reads queue state.
        let metadata = try finalFiles.map { item in
            let (type, url, mime) = item
            let relative = rootDirectory.standardizedFileURL.path == url.deletingLastPathComponent().standardizedFileURL.path
                ? url.lastPathComponent : url.path.replacingOccurrences(of: rootDirectory.path + "/", with: "")
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return (type: type, url: url, mime: mime, relative: relative, size: size, hash: try Self.sha256File(url))
        }
        try Task.checkCancellation()
        try transaction {
            for item in metadata {
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
                        .text(UUID().uuidString), .text(recording.id.uuidString), .text(item.type),
                        .text(item.url.lastPathComponent), .text(item.relative), .text(item.mime),
                        .integer(item.size), .text(item.hash), .text(now),
                    ]
                )
            }
            try execute(
                "INSERT OR REPLACE INTO recording_sync(recording_id,sync_json,updated_at_utc) VALUES(?,?,?)",
                [.text(recording.id.uuidString), .text(String(data: syncJSON, encoding: .utf8)!), .text(now)]
            )
            try execute(
                "UPDATE recordings SET status=?,ended_at_utc=?,server_sync_state='pending' WHERE id=?",
                [.text(status), .text(endedAt), .text(recording.id.uuidString)]
            )
            if let timing, let duration = timing.durationSeconds,
               var questionnaire = recording.questionnaire, questionnaire.schemaVersion == 2 && recording.source == "live" {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: recording.timezone)
                formatter.dateFormat = "HH:mm"
                questionnaire.endTime = formatter.string(from: timing.endedAt)
                questionnaire.durationMinutes = duration / 60
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
            let needsReview = try captureRecoveryRequiresReview(recording.id)
            if recording.questionnaire?.readyForSync != false && !needsReview { values.append(recording) }
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
                [.text(id.uuidString), .text(state), error.map { .text(safeSyncDiagnostic($0.localizedDescription)) } ?? .null, .text(now)]
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

    /// Recover only proven recording-directory files. Old timestamp-named
    /// working dumps have no persisted recording UUID and must not be assigned
    /// by guessed timestamps. They remain available in the complete export.
    @discardableResult
    func recoverUnfinishedCaptures(excluding activeRecordings: Set<UUID> = []) throws -> Int {
        let query = try prepare("SELECT id FROM recordings WHERE status IN ('preparing','recording')")
        var ids: [UUID] = []
        while sqlite3_step(query) == SQLITE_ROW {
            if let id = UUID(uuidString: columnText(query, 0)), !activeRecordings.contains(id) { ids.append(id) }
        }
        sqlite3_finalize(query)
        let known: [(String, String, String)] = [
            ("packets.bin", "packet", "application/octet-stream"),
            ("packet_timeline.bin", "packet_timeline", "application/octet-stream"),
            ("raw_fragments.binlog", "raw", "application/octet-stream"),
            ("diagnostics.log", "diagnostic", "text/plain"), ("sync.json", "sync", "application/json"),
            ("video.mp4", "video", "video/mp4"), ("channel.csv", "csv", "text/csv")]
        var recovered = 0
        for id in ids {
            try Task.checkCancellation()
            guard let recording = try recording(id: id) else { continue }
            let directory = try localDeletionURL(recording.relativeDirectory)
            let files = try known.compactMap { item -> (String, String, String, Int64, String)? in
                let (name, type, _) = item
                let url = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let relative = recording.relativeDirectory + "/" + name
                _ = try localDeletionURL(relative)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = (attributes[.size] as? NSNumber)?.int64Value else {
                    throw WoonaStoreError.invalidData("Interrupted capture contains an unsafe source file: " + name)
                }
                return (relative, name, type, size, try Self.sha256File(url))
            }
            let now = Self.iso8601(Date())
            let message = "capture_recovery_requires_review: The previous process ended before capture finalization. Existing source files and questionnaires are preserved. Capture end time and unassigned legacy working files are unknown; export all data for review. Automatic upload remains paused."
            var changed = false
            try transaction {
                guard let latest = try self.recording(id: id), ["preparing", "recording"].contains(latest.status) else { return }
                for (relative, name, type, size, hash) in files {
                    let mime = known.first { $0.0 == name }!.2
                    try execute("""
                        INSERT OR IGNORE INTO artifacts(id,recording_id,type,file_name,relative_path,mime_type,size_bytes,sha256,upload_state,uploaded_bytes,created_at_utc)
                        VALUES(?,?,?,?,?,?,?,?,'pending',0,?)
                        """, [.text(UUID().uuidString), .text(id.uuidString), .text(type), .text(name), .text(relative), .text(mime), .integer(size), .text(hash), .text(now)])
                }
                // Preserve any existing sync artifact and anchors byte for byte.
                let sync = directory.appendingPathComponent("sync.json")
                if FileManager.default.fileExists(atPath: sync.path), let data = try? Data(contentsOf: sync),
                   (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
                    try execute("INSERT OR IGNORE INTO recording_sync(recording_id,sync_json,updated_at_utc) VALUES(?,?,?)",
                        [.text(id.uuidString), .text(String(decoding: data, as: UTF8.self)), .text(now)])
                }
                try execute("UPDATE recordings SET status='interrupted',server_sync_state='permanent_error' WHERE id=?", [.text(id.uuidString)])
                try execute("""
                    INSERT INTO server_sync_state(recording_id,state,attempt_count,last_error_code,last_error_message,updated_at_utc)
                    VALUES(?,'permanent_error',0,'capture_recovery_requires_review',?,?)
                    ON CONFLICT(recording_id) DO UPDATE SET state='permanent_error',last_error_code='capture_recovery_requires_review',last_error_message=excluded.last_error_message,updated_at_utc=excluded.updated_at_utc
                    """, [.text(id.uuidString), .text(message), .text(now)])
                changed = true
            }
            if changed { recovered += 1 }
        }
        return recovered
    }

    func captureRecoveryRequiresReview(_ recordingID: UUID) throws -> Bool {
        let query = try prepare("SELECT 1 FROM server_sync_state WHERE recording_id=? AND last_error_code='capture_recovery_requires_review'", [.text(recordingID.uuidString)])
        defer { sqlite3_finalize(query) }
        return sqlite3_step(query) == SQLITE_ROW
    }

    func resetFailedSync() throws {
        let now = Self.iso8601(Date())
        try transaction {
            try execute("UPDATE profile_sync_state SET state='pending',last_error=NULL,updated_at_utc=? WHERE state IN ('retryable_error','permanent_error')", [.text(now)])
            try execute(
                "UPDATE recordings SET server_sync_state='pending' WHERE server_sync_state IN ('retryable_error','permanent_error') AND id NOT IN (SELECT recording_id FROM server_sync_state WHERE last_error_code='capture_recovery_requires_review')"
            )
            try execute(
                "UPDATE server_sync_state SET state='pending',updated_at_utc=? WHERE state IN ('retryable_error','permanent_error') AND COALESCE(last_error_code,'')!='capture_recovery_requires_review'",
                [.text(now)]
            )
        }
    }

    private func decodeRecording(_ statement: OpaquePointer?) throws -> WoonaRecording {
        guard let id = UUID(uuidString: columnText(statement, 0)) else { throw WoonaStoreError.invalidData("Invalid recording UUID") }
        return try decodeRecording(statement, syncData: syncJSON(recordingID: id), needsRecoveryReview: captureRecoveryRequiresReview(id))
    }

    private func decodeRecording(_ statement: OpaquePointer?, syncData: Data?, needsRecoveryReview: Bool) throws -> WoonaRecording {
        guard let id = UUID(uuidString: columnText(statement, 0)),
              let dogID = UUID(uuidString: columnText(statement, 1)),
              let versionID = UUID(uuidString: columnText(statement, 2)) else { throw WoonaStoreError.invalidData("Invalid recording UUID") }
        let sync = syncData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
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
            captureErrorCode: needsRecoveryReview ? "process_interrupted" : sync?["captureErrorCode"] as? String,
            captureErrorMessage: needsRecoveryReview ? "Previous process ended before capture finalization. Source files are preserved; export all data for timing and source review." : sync?["captureErrorMessage"] as? String
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
        // DDL and queue seeding are one transaction: an interrupted/failed upgrade
        // must not leave a partly upgraded database or advance user_version.
        try transaction { try migrateSchema() }
    }

    private func migrateSchema() throws {
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
        try execute("""
            CREATE TABLE IF NOT EXISTS profile_sync_state(
              profile_version_id TEXT PRIMARY KEY REFERENCES dog_profile_versions(id) ON DELETE CASCADE,
              state TEXT NOT NULL DEFAULT 'pending',last_error TEXT,updated_at_utc TEXT NOT NULL
            )
            """)
        // Historical dog revisions contain no per-version acceptance proof. Reconcile
        // current UUIDs idempotently with the server instead of guessing 'synced'.
        try execute("INSERT OR IGNORE INTO profile_sync_state(profile_version_id,state,updated_at_utc) SELECT id,'pending',client_created_at_utc FROM dog_profile_versions")
        try execute("""
            CREATE TABLE IF NOT EXISTS local_deletion_outbox(
              id TEXT PRIMARY KEY,relative_path TEXT NOT NULL,
              entry_kind TEXT NOT NULL CHECK(entry_kind IN ('directory','file')),
              created_at_utc TEXT NOT NULL,last_error TEXT,
              UNIQUE(relative_path,entry_kind)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS deferred_retirements(
              kind TEXT NOT NULL,id_sha256 TEXT NOT NULL,received_at_utc TEXT NOT NULL,
              PRIMARY KEY(kind,id_sha256)
            )
            """)
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
        try execute("CREATE INDEX IF NOT EXISTS recordings_history_order ON recordings(dog_id,\(Self.historySortSQL()) DESC,id DESC)")
        try execute("PRAGMA user_version=8")
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
#if DEBUG
        queryCountForTesting += 1
#endif
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
#if DEBUG
        // Distinguish filesystem/locking failures during native QA without
        // logging SQL, paths, account identifiers or credentials.
        let extended = sqlite3_extended_errcode(database)
        let system = sqlite3_system_errno(database)
        return WoonaStoreError.sqlite("\(String(cString: sqlite3_errmsg(database))) [sqliteExtended=\(extended), systemErrno=\(system)]")
#else
        return WoonaStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
#endif
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
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
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
        let details: [(String, String?, Bool)] = [
            ("knownHeartConditionDetails", knownHeartConditionDetails, knownHeartCondition?.key == "yes"),
            ("heartRelevantMedicationDetails", heartRelevantMedicationDetails, heartRelevantMedication?.key == "yes"),
            ("referenceArtifact", referenceArtifact, ["ecg", "polar_rr"].contains(referenceMethod?.key ?? ""))
        ]
        for (key, detail, active) in details where active {
            if (detail?.count ?? 0) > 2000 { errors[key] = "Максимум 2000 символов" }
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
