import AVFoundation
import SwiftUI

enum HostClock {
    static func nowNanoseconds() -> UInt64 {
        nanoseconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    static func nanoseconds(_ time: CMTime) -> UInt64 {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000)
    }
}

struct CameraCaptureInfo: Codable, Equatable {
    let requestedMonotonicNs: UInt64
    let writerStartedMonotonicNs: UInt64?
    let firstFrameMonotonicNs: UInt64?
    let firstFrameCameraTimestampNs: UInt64?
    let firstFrameCallbackMonotonicNs: UInt64?
    let firstVideoSamplePtsUs: UInt64?
    let timestampSource: String
    let clockQuality: String
    let width: Int
    let height: Int
    let frameRate: Int
    let durationNs: UInt64
}

enum CameraRecorderError: LocalizedError {
    case permissionDenied
    case unavailable
    case cannotConfigure
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Camera permission denied"
        case .unavailable: "Rear camera is unavailable"
        case .cannotConfigure: "Unable to configure camera capture"
        case .writer(let message): message
        }
    }
}

// Admission is independent of Task cancellation: AVFoundation permission callbacks may
// resume after Stop. The lock covers only the generation snapshot, never AVFoundation
// calls. Already-admitted mutations run on the serial camera queue; Stop drains that
// queue before completion, so invalidation never blocks the main actor on camera work.
final class CameraGenerationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    @discardableResult
    func advance() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func withCurrent<T>(_ token: UInt64, _ operation: () throws -> T) throws -> T {
        lock.lock()
        let admitted = token == generation
        lock.unlock()
        guard admitted else { throw CancellationError() }
        return try operation()
    }
}

final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onRecordingFailure: (@Sendable (UInt64, String) -> Void)?
    let generationFence = CameraGenerationFence()
    private var writerGeneration: UInt64 = 0
    let session = AVCaptureSession()
    lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        return layer
    }()

    private let queue = DispatchQueue(label: "com.woona.camera", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var configured = false
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var requestedMonotonicNs: UInt64 = 0
    private var writerStartedMonotonicNs: UInt64?
    private var firstFrameMonotonicNs: UInt64?
    private var firstFrameCameraTimestampNs: UInt64?
    private var firstFrameCallbackMonotonicNs: UInt64?
    private var firstVideoSamplePtsUs: UInt64?
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var timestampSource = "unknown"
    private var clockQuality = "unavailable"
    private var width = 1_920
    private var height = 1_080
    private var isRecording = false
    private var writerFailure: CameraRecorderError?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    private let permissionCheck: () async throws -> Void
    private let prepareSessionOverride: (() throws -> Void)?
    private let afterPreparation: (() async -> Void)?

    init(permissionCheck: @escaping () async throws -> Void = CameraRecorder.authorize,
         prepareSession: (() throws -> Void)? = nil,
         afterPreparation: (() async -> Void)? = nil) {
        self.permissionCheck = permissionCheck
        self.prepareSessionOverride = prepareSession
        self.afterPreparation = afterPreparation
        super.init()
    }

    static func authorize() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraRecorderError.permissionDenied }
        default: throw CameraRecorderError.permissionDenied
        }
    }

    func prepare(generation: UInt64) async throws {
        try await permissionCheck()
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.generationFence.withCurrent(generation) {
                        if let override = self.prepareSessionOverride { try override() }
                        else {
                            try self.configureIfNeeded()
                            if !self.session.isRunning { self.session.startRunning() }
                        }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func startRecording(to url: URL, generation: UInt64) async throws -> UInt64 {
        try await prepare(generation: generation)
        if let afterPreparation { await afterPreparation() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let requested = try self.generationFence.withCurrent(generation) {
                        guard self.writer == nil else { throw CameraRecorderError.writer("Previous writer is still active") }
                        // A fresh recording directory owns this pending path. Never remove
                        // historical canonical output or failed bytes from an earlier attempt.
                        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                        let input = AVAssetWriterInput(
                            mediaType: .video,
                            outputSettings: [
                                AVVideoCodecKey: AVVideoCodecType.h264,
                                AVVideoWidthKey: self.width,
                                AVVideoHeightKey: self.height,
                            ]
                        )
                        input.expectsMediaDataInRealTime = true
                        let angle = self.rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 0
                        input.transform = CGAffineTransform(rotationAngle: angle * .pi / 180)
                        guard writer.canAdd(input) else { throw CameraRecorderError.cannotConfigure }
                        writer.add(input)
                        self.writer = writer
                        self.writerInput = input
                        self.outputURL = url
                        self.requestedMonotonicNs = HostClock.nowNanoseconds()
                        self.writerStartedMonotonicNs = nil
                        self.firstFrameMonotonicNs = nil
                        self.firstFrameCameraTimestampNs = nil
                        self.firstFrameCallbackMonotonicNs = nil
                        self.firstVideoSamplePtsUs = nil
                        self.firstPresentationTime = nil
                        self.lastPresentationTime = nil
                        self.timestampSource = "unknown"
                        self.clockQuality = "unavailable"
                        self.writerFailure = nil
                        self.writerGeneration = generation
                        self.isRecording = true
                        return self.requestedMonotonicNs
                    }
                    continuation.resume(returning: requested)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stopRecording() async throws -> CameraCaptureInfo? {
        generationFence.advance()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.isRecording else {
                    if let writerFailure = self.writerFailure {
                        let pendingWriter = self.writer
                        if pendingWriter?.status == .writing { self.writerInput?.markAsFinished() }
                        self.writer = nil
                        self.writerInput = nil
                        self.outputURL = nil
                        self.writerFailure = nil
                        if let pendingWriter, pendingWriter.status == .writing {
                            pendingWriter.finishWriting { continuation.resume(throwing: writerFailure) }
                        } else {
                            continuation.resume(throwing: writerFailure)
                        }
                    } else {
                        continuation.resume(returning: nil)
                    }
                    return
                }
                self.isRecording = false
                guard let writer = self.writer, let input = self.writerInput else {
                    continuation.resume(throwing: CameraRecorderError.writer("Video writer was not initialized"))
                    return
                }
                guard writer.status != .unknown else {
                    self.writer = nil
                    self.writerInput = nil
                    self.outputURL = nil
                    continuation.resume(throwing: CameraRecorderError.writer("No camera frames were recorded"))
                    return
                }
                input.markAsFinished()
                writer.finishWriting {
                    self.queue.async {
                        defer { self.writer = nil; self.writerInput = nil; self.outputURL = nil; self.writerFailure = nil }
                        guard writer.status == .completed else {
                            continuation.resume(throwing: CameraRecorderError.writer(writer.error?.localizedDescription ?? "Video finalization failed"))
                            return
                        }
                        guard
                            let outputURL = self.outputURL,
                            let size = try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber,
                            size.int64Value > 0
                        else {
                            continuation.resume(throwing: CameraRecorderError.writer("Finalized video is empty"))
                            return
                        }
                        let first = self.firstPresentationTime.map(HostClock.nanoseconds) ?? 0
                        let last = self.lastPresentationTime.map(HostClock.nanoseconds) ?? first
                        let storedPts: UInt64
                        do { storedPts = try self.firstStoredVideoPtsUs(outputURL) }
                        catch { continuation.resume(throwing: error); return }
                        continuation.resume(
                            returning: CameraCaptureInfo(
                                requestedMonotonicNs: self.requestedMonotonicNs,
                                writerStartedMonotonicNs: self.writerStartedMonotonicNs,
                                firstFrameMonotonicNs: self.firstFrameMonotonicNs,
                                firstFrameCameraTimestampNs: self.firstFrameCameraTimestampNs,
                                firstFrameCallbackMonotonicNs: self.firstFrameCallbackMonotonicNs,
                                firstVideoSamplePtsUs: storedPts,
                                timestampSource: self.timestampSource,
                                clockQuality: self.clockQuality,
                                width: self.width,
                                height: self.height,
                                frameRate: 30,
                                durationNs: last >= first ? last - first : 0
                            )
                        )
                    }
                }
            }
        }
    }

    // The info must come from successful stopRecording media validation. Failed
    // pending bytes stay in the recording directory for complete-data export,
    // but are never canonical artifacts or discovered by upload.
    static func promoteCompletedVideo(in directory: URL, info: CameraCaptureInfo?) throws -> URL? {
        guard info != nil else { return nil }
        let canonical = directory.appendingPathComponent("video.mp4")
        try FileManager.default.moveItem(at: directory.appendingPathComponent("video.pending.mp4"), to: canonical)
        return canonical
    }

    func stopPreview() {
        generationFence.advance()
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func firstStoredVideoPtsUs(_ url: URL) throws -> UInt64 {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw CameraRecorderError.writer("Saved video has no track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer() else {
            throw CameraRecorderError.writer("Saved video has no sample")
        }
        defer { reader.cancelReading() }
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard seconds.isFinite, seconds >= 0 else { throw CameraRecorderError.writer("Invalid saved video PTS") }
        return UInt64((seconds * 1_000_000).rounded())
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording, CMSampleBufferDataIsReady(sampleBuffer), let writer, let writerInput else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let callbackTime = HostClock.nowNanoseconds()
        if writer.status == .unknown {
            guard writer.startWriting() else {
                let message = writer.error?.localizedDescription ?? "Video writer failed to start"
                writerFailure = .writer(message)
                isRecording = false
                onRecordingFailure?(writerGeneration, message)
                return
            }
            writer.startSession(atSourceTime: presentationTime)
            writerStartedMonotonicNs = callbackTime
        }
        guard writer.status == .writing, writerInput.isReadyForMoreMediaData else { return }
        guard writerInput.append(sampleBuffer) else {
            let message = writer.error?.localizedDescription ?? "Video writer rejected a frame"
            writerFailure = .writer(message)
            isRecording = false
            onRecordingFailure?(writerGeneration, message)
            return
        }
        if firstPresentationTime == nil {
            firstPresentationTime = presentationTime
            firstVideoSamplePtsUs = UInt64(max(CMTimeGetSeconds(presentationTime), 0) * 1_000_000)
            firstFrameCallbackMonotonicNs = callbackTime
            if let clock = session.synchronizationClock {
                let hostTime = clock.convertTime(presentationTime, to: CMClockGetHostTimeClock())
                firstFrameMonotonicNs = HostClock.nanoseconds(hostTime)
                firstFrameCameraTimestampNs = HostClock.nanoseconds(presentationTime)
                timestampSource = "avfoundation_session_clock"
                clockQuality = "hardware_monotonic"
            } else {
                firstFrameMonotonicNs = callbackTime
                timestampSource = "unknown"
                clockQuality = "callback_estimate"
            }
        }
        lastPresentationTime = presentationTime
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraRecorderError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: camera)
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: previewLayer)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CameraRecorderError.cannotConfigure }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        width = min(Int(dimensions.width), 1_920)
        height = min(Int(dimensions.height), 1_080)
        do {
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            camera.unlockForConfiguration()
        } catch {
            // The selected format can reject 30 fps; capture still remains valid at its native rate.
        }
        configured = true
    }
}

struct CameraPreview: UIViewRepresentable {
    let recorder: CameraRecorder

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layer.addSublayer(recorder.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        recorder.previewLayer.frame = view.bounds
    }

    final class PreviewView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.sublayers?.forEach { $0.frame = bounds }
        }
    }
}
