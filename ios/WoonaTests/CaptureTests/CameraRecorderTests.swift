import XCTest
@testable import Woona

final class CameraRecorderTests: XCTestCase {
    func testStopDuringPermissionDoesNotWaitForPermissionOrAllowLatePreview() async throws {
        let entered = expectation(description: "permission suspended")
        let permission = CameraSuspension(entered: entered)
        let mutations = CameraMutationCount()
        let recorder = CameraRecorder(permissionCheck: { await permission.wait() }, prepareSession: { mutations.increment() })
        let token = recorder.generationFence.advance()
        let prepare = Task { try await recorder.prepare(generation: token) }
        await fulfillment(of: [entered], timeout: 2)

        let stopped = expectation(description: "Stop completes while permission is still pending")
        let stop = Task {
            let info = try await recorder.stopRecording()
            XCTAssertNil(info)
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 2)
        // Cancellation is intentionally ignored by the suspension, like permission UI.
        prepare.cancel()
        await permission.release()
        do { try await prepare.value; XCTFail("Stale prepare must reject") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await stop.value
        XCTAssertEqual(mutations.value, 0)

        let next = recorder.generationFence.advance()
        try await recorder.prepare(generation: next)
        XCTAssertEqual(mutations.value, 1, "A fresh capture must still prepare")
        recorder.stopPreview()
    }

    func testStopBetweenPreparationAndWriterInstallationRejectsLateStart() async throws {
        let entered = expectation(description: "prepared, writer not installed")
        let installation = CameraSuspension(entered: entered)
        let recorder = CameraRecorder(permissionCheck: {}, prepareSession: {}, afterPreparation: { await installation.wait() })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pending = root.appendingPathComponent("video.pending.mp4")
        let token = recorder.generationFence.advance()
        let start = Task { try await recorder.startRecording(to: pending, generation: token) }
        await fulfillment(of: [entered], timeout: 2)
        let info = try await recorder.stopRecording()
        XCTAssertNil(info)
        await installation.release()
        do { _ = try await start.value; XCTFail("Late writer must reject") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        let again = try await recorder.stopRecording()
        XCTAssertNil(again, "Repeated Stop is harmless")
    }

    func testBackgroundAndDisconnectInvalidationRejectBothPreviewAndWriterAdmissions() throws {
        for _ in ["background", "disconnect"] {
            let fence = CameraGenerationFence()
            let old = fence.advance()
            fence.advance() // same synchronous admission invalidation as AppViewModel Stop
            for _ in ["preview", "writer"] {
                XCTAssertThrowsError(try fence.withCurrent(old) { XCTFail("Late mutation") })
            }
            let next = fence.advance()
            XCTAssertEqual(try fence.withCurrent(next) { 1 }, 1)
            XCTAssertThrowsError(try fence.withCurrent(old) { 2 })
        }
    }

    func testInvalidationDoesNotWaitForAlreadyAdmittedSlowCameraMutation() async {
        let fence = CameraGenerationFence()
        let token = fence.advance()
        let entered = expectation(description: "camera mutation admitted")
        let invalidated = expectation(description: "invalidation must not wait for camera work")
        let drained = expectation(description: "admitted mutation drained")
        let release = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "camera.slow-mutation.fixture")
        queue.async {
            try? fence.withCurrent(token) {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        DispatchQueue.global().async { fence.advance(); invalidated.fulfill() }
        await fulfillment(of: [invalidated], timeout: 1)
        // Stop's serial-queue drain must still follow already-admitted work.
        queue.async { drained.fulfill() }
        release.signal()
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertThrowsError(try fence.withCurrent(token) { XCTFail("Stale work after drain") })
    }

    func testNoFramesWriterNeverYieldsValidatedCompletion() async throws {
        let recorder = CameraRecorder(permissionCheck: {}, prepareSession: {})
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pending = root.appendingPathComponent("video.pending.mp4")
        let token = recorder.generationFence.advance()
        _ = try await recorder.startRecording(to: pending, generation: token)
        do { _ = try await recorder.stopRecording(); XCTFail("No-frame writer cannot validate") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No camera frames")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("video.mp4").path))
    }

    func testUnvalidatedPendingOutputIsRetainedButNeverPromoted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pending = root.appendingPathComponent("video.pending.mp4")
        for bytes in [Data(), Data("unknown-writer".utf8), Data("failed-writer".utf8)] {
            try bytes.write(to: pending)
            XCTAssertNil(try CameraRecorder.promoteCompletedVideo(in: root, info: nil))
            XCTAssertEqual(try Data(contentsOf: pending), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("video.mp4").path))
        }
    }

    func testValidatedCompletionPromotesWithoutOverwritingHistoricalCanonical() throws {
        // Admission-policy fixture only, not an AVFoundation playable-media test.
        let info = CameraCaptureInfo(requestedMonotonicNs: 1, writerStartedMonotonicNs: 2,
            firstFrameMonotonicNs: 3, firstFrameCameraTimestampNs: 3, firstFrameCallbackMonotonicNs: 4,
            firstVideoSamplePtsUs: 0, timestampSource: "fixture", clockQuality: "fixture",
            width: 1920, height: 1080, frameRate: 30, durationNs: 10)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pending = root.appendingPathComponent("video.pending.mp4")
        let canonical = root.appendingPathComponent("video.mp4")
        try Data("completed-policy-fixture".utf8).write(to: pending)
        XCTAssertEqual(try CameraRecorder.promoteCompletedVideo(in: root, info: info), canonical)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        try Data("later-attempt".utf8).write(to: pending)
        XCTAssertThrowsError(try CameraRecorder.promoteCompletedVideo(in: root, info: info))
        XCTAssertEqual(try Data(contentsOf: canonical), Data("completed-policy-fixture".utf8))
        XCTAssertEqual(try Data(contentsOf: pending), Data("later-attempt".utf8))
    }
}

private actor CameraSuspension {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class CameraMutationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
