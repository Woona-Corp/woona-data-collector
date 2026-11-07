import XCTest
@testable import Woona

final class CaptureDiagnosticDetailsTests: XCTestCase {
    private func fixture() throws -> (URL, WoonaStore, WoonaRecording) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try WoonaStore(rootDirectory: root)
        var questionnaire = DogQuestionnaire()
        questionnaire.numberOrName = "Synthetic diagnostic fixture"
        questionnaire.shelterOrPlace = "Synthetic shelter"
        questionnaire.breedStatus = "unknown"
        questionnaire.size = "unknown"
        questionnaire.ageStatus = "unknown"
        questionnaire.ageSource = "unknown"
        questionnaire.sex = "unknown"
        questionnaire.sterilizationStatus = "unknown"
        questionnaire.weightStatus = "unknown"
        questionnaire.bodyConditionStatus = "unable"
        questionnaire.muscleMass = "unable"
        questionnaire.neckCircumferenceStatus = "not_measured"
        questionnaire.coatLength = "unknown"
        questionnaire.undercoat = "unknown"
        questionnaire.shavedAreasStatus = "unknown"
        questionnaire.observedSigns = ["none"]
        questionnaire.diagnosesStatus = "unknown"
        questionnaire.housing = "unknown"
        questionnaire.walksStatus = "unknown"
        questionnaire.cohabitants = "unknown"
        questionnaire.shelterPermission = "unknown"
        questionnaire.notesStatus = "none"
        let profile = try store.saveProfile(questionnaire)
        var session = SessionQuestionnaire()
        session.sessionLabel = "Synthetic session"
        session.operatorName = "Synthetic operator"
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
        let recording = try store.createRecording(profile: profile, source: "live", questionnaire: session)
        return (root, store, recording)
    }

    func testCapturePreviewMissingEmptyAndUnknownRecordingAreExplicitlyUnavailable() throws {
        let (root, store, recording) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(CaptureDiagnosticPreview.load(recordingID: recording.id, store: store, secret: nil))
        XCTAssertNil(CaptureDiagnosticPreview.load(recordingID: UUID(), store: store, secret: nil))
        let file = store.directory(for: recording).appendingPathComponent("diagnostics.log")
        try Data().write(to: file)
        XCTAssertNil(CaptureDiagnosticPreview.load(recordingID: recording.id, store: store, secret: nil))
    }

    func testCapturePreviewReadsOnlyBoundedTailAndDoesNotMutateFile() throws {
        let (root, store, recording) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = store.directory(for: recording).appendingPathComponent("diagnostics.log")
        let original = Data(("excluded-prefix\n" + String(repeating: "z", count: 40_000)).utf8)
        try original.write(to: file)
        let text = try XCTUnwrap(CaptureDiagnosticPreview.load(recordingID: recording.id, store: store, secret: nil))
        XCTAssertEqual(CaptureDiagnosticPreview.maximumTailBytes, 32 * 1024)
        XCTAssertEqual(text, String(repeating: "z", count: 8192))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testCapturePreviewSanitizesActualDiagnosticTextAndExactConfiguredSecret() throws {
        let (root, store, recording) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = store.directory(for: recording).appendingPathComponent("diagnostics.log")
        try Data("GATT 133\nBearer synthetic-bearer\ntoken=synthetic-token\nsynthetic-exact-secret".utf8).write(to: file)
        let text = try XCTUnwrap(CaptureDiagnosticPreview.load(recordingID: recording.id, store: store, secret: "synthetic-exact-secret"))
        XCTAssertTrue(text.contains("GATT 133"))
        for secret in ["synthetic-bearer", "synthetic-token", "synthetic-exact-secret"] {
            XCTAssertFalse(text.contains(secret))
        }
    }

    func testCapturePreviewRejectsSymlinkEvenToAnotherRecordingInsideRepository() throws {
        let (root, store, recording) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("other-recording.log")
        try Data("must not be shown".utf8).write(to: target)
        let file = store.directory(for: recording).appendingPathComponent("diagnostics.log")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertNil(CaptureDiagnosticPreview.load(recordingID: recording.id, store: store, secret: nil))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "must not be shown")
    }
}
