import AVFoundation
import UIKit
import CoreImage
import CoreGraphics
import Foundation
import VideoToolbox

final class WhisperVideoStream: NSObject {
    enum StreamError: Error {
        case permissionDenied
        case noCamera
        case configurationFailed
    }

    enum VideoCodecKind {
        case jpeg
        case h264
    }

    var onFrame: ((Data, Int, Int) -> Void)?
    var onError: ((Error) -> Void)?
    var onPreviewImage: ((UIImage) -> Void)?

    var targetInterval: TimeInterval {
        guard targetFps > 0 else { return 0.04 }
        return 1.0 / targetFps
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "whisper.video.capture")
    private let captureQueueKey = DispatchSpecificKey<Void>()
    private let context = CIContext()
    private let codecKind: VideoCodecKind
    private var compressionSession: VTCompressionSession?
    private var compressionWidth: Int = 0
    private var compressionHeight: Int = 0
    private var frameCounter: Int64 = 0
    private var lastPreviewAt: CFTimeInterval = 0
    private var renderBufferPool: CVPixelBufferPool?
    private var renderBufferSize: CGSize = .zero

    private var baseTargetSize: CGSize
    private var targetBitrateKbps: Int
    private var targetFps: Double
    private var lastFrameAt: CFTimeInterval = 0
    private var isRunning = false
    private var isStarting = false
    private var currentPosition: AVCaptureDevice.Position = .front
    private var currentInput: AVCaptureDeviceInput?
    private var outputOrientation: AVCaptureVideoOrientation = .portrait
    private var outputMirrored = false
    private var sessionObservers: [NSObjectProtocol] = []

    init(profile: WhisperVideoProfile, bitrateKbps: Int, fps: Double, codec: VideoCodecKind = .jpeg) {
        self.baseTargetSize = CGSize(width: profile.width, height: profile.height)
        self.targetBitrateKbps = bitrateKbps
        self.targetFps = fps
        self.codecKind = codec
        super.init()
        captureQueue.setSpecific(key: captureQueueKey, value: ())
    }

    func start() throws {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        var thrown: Error?
        captureQueue.sync {
            do { try self.configureSession() } catch { thrown = error }
        }
        if let thrown {
            isStarting = false
            throw thrown
        }
        captureQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.isRunning = true
            self.isStarting = false
        }
    }

    func resume() throws {
        guard !isRunning, !isStarting else { return }
        try start()
    }

    func stop() {
        guard isRunning || isStarting else { return }
        isStarting = false
        captureQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            if let session = self.compressionSession {
                VTCompressionSessionInvalidate(session)
                self.compressionSession = nil
            }
            self.renderBufferPool = nil
            self.isRunning = false
            self.lastFrameAt = 0
            self.lastPreviewAt = 0
            self.removeSessionObservers()
        }
    }

    func updateTarget(profile: WhisperVideoProfile, bitrateKbps: Int, fps: Double) {
        baseTargetSize = CGSize(width: profile.width, height: profile.height)
        targetBitrateKbps = bitrateKbps
        targetFps = fps
        if codecKind == .h264 {
            captureQueue.async { [weak self] in
                guard let self else { return }
                try? self.setupCompressionSessionIfNeeded(forceRecreate: true)
                self.updateCompressionBitrate()
            }
        }
    }

    private var outputTargetSize: CGSize {
        switch outputOrientation {
        case .portrait, .portraitUpsideDown:
            return CGSize(width: baseTargetSize.height, height: baseTargetSize.width)
        default:
            return baseTargetSize
        }
    }

    private var previewTargetSize: CGSize {
        let target = outputTargetSize
        let maxSide: CGFloat = 360
        let maxDim = max(target.width, target.height)
        guard maxDim > maxSide else { return target }
        let scale = maxSide / maxDim
        return CGSize(width: target.width * scale, height: target.height * scale)
    }

    func switchCamera() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            let nextPosition: AVCaptureDevice.Position = (self.currentPosition == .front) ? .back : .front
            guard let device = self.resolveDevice(position: nextPosition) else {
                self.onError?(StreamError.noCamera)
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                let updated = self.replaceInput(input)
                self.session.commitConfiguration()
                if updated {
                    self.currentPosition = nextPosition
                    self.configureOutputConnection()
                    self.applyPreferredFormat(to: device)
                    self.applyDefaultZoom(to: device)
                } else {
                    self.onError?(StreamError.configurationFailed)
                }
            } catch {
                self.session.commitConfiguration()
                self.onError?(error)
            }
        }
    }

    private func resolveDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
    }

    private func applyPreferredFormat(to device: AVCaptureDevice) {
        let targetWidth = Int(max(baseTargetSize.width, baseTargetSize.height))
        let targetWidthInt32 = Int32(targetWidth * 2)
        let desiredFps = max(24.0, min(30.0, targetFps))
        let aspectTarget: Double = 16.0 / 9.0
        let candidates: [(AVCaptureDevice.Format, CMVideoDimensions, Double)] = device.formats.compactMap { format -> (AVCaptureDevice.Format, CMVideoDimensions, Double)? in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if dims.width <= 0 || dims.height <= 0 { return nil }
            let aspect = Double(dims.width) / Double(dims.height)
            return (format, dims, aspect)
        }
        let filtered = candidates.filter { _, dims, aspect in
            abs(aspect - aspectTarget) < 0.12 && dims.width <= targetWidthInt32
        }
        let sorted = filtered.sorted { lhs, rhs in
            let lp = Int(lhs.1.width) * Int(lhs.1.height)
            let rp = Int(rhs.1.width) * Int(rhs.1.height)
            return lp > rp
        }
        guard let pick = sorted.first(where: { format, _, _ in
            format.videoSupportedFrameRateRanges.contains { range in
                desiredFps >= range.minFrameRate && desiredFps <= range.maxFrameRate
            }
        }) ?? sorted.first else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = pick.0
            let timescale = CMTimeScale(Int32(desiredFps.rounded()))
            let frameDuration = CMTime(value: 1, timescale: timescale)
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }

    private func applyDefaultZoom(to device: AVCaptureDevice) {
        let minZoom: CGFloat
        if #available(iOS 13.0, *) {
            minZoom = device.minAvailableVideoZoomFactor
        } else {
            minZoom = 1.0
        }
        let targetZoom = max(1.0, minZoom)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = targetZoom
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }

    private func configureSession() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .denied || status == .restricted {
            throw StreamError.permissionDenied
        }
        guard let device = resolveDevice(position: currentPosition) else {
            throw StreamError.noCamera
        }
        applyPreferredFormat(to: device)
        applyDefaultZoom(to: device)
        session.automaticallyConfiguresApplicationAudioSession = false
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        } else {
            session.sessionPreset = .high
        }
        guard replaceInput(input) else {
            session.commitConfiguration()
            throw StreamError.configurationFailed
        }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        if session.outputs.isEmpty {
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw StreamError.configurationFailed
            }
            session.addOutput(output)
        }
        configureOutputConnection()
        if codecKind == .h264 {
            try setupCompressionSessionIfNeeded()
        }
        output.setSampleBufferDelegate(self, queue: captureQueue)
        session.commitConfiguration()
        registerSessionObserversIfNeeded()
    }

    @discardableResult
    private func replaceInput(_ input: AVCaptureDeviceInput) -> Bool {
        session.inputs.forEach { session.removeInput($0) }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        currentInput = input
        return true
    }

    private func shouldEmitFrame(now: CFTimeInterval) -> Bool {
        if lastFrameAt == 0 {
            lastFrameAt = now
            return true
        }
        let interval = now - lastFrameAt
        if interval >= targetInterval {
            lastFrameAt = now
            return true
        }
        return false
    }

    private func configureOutputConnection() {
        if let connection = output.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = (currentPosition == .front)
            }
            outputOrientation = connection.videoOrientation
            outputMirrored = connection.isVideoMirrored
        }
    }

    private func registerSessionObserversIfNeeded() {
        guard sessionObservers.isEmpty else { return }
        let runtimeObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError,
                                                                     object: session,
                                                                     queue: nil) { [weak self] _ in
            guard let self else { return }
            self.captureQueue.async {
                if self.session.isRunning == false {
                    self.session.startRunning()
                }
            }
        }
        let interruptionObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted,
                                                                          object: session,
                                                                          queue: nil) { _ in
        }
        let resumeObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                                                                    object: session,
                                                                    queue: nil) { [weak self] _ in
            guard let self else { return }
            self.captureQueue.async {
                if self.session.isRunning == false {
                    self.session.startRunning()
                }
            }
        }
        sessionObservers = [runtimeObserver, interruptionObserver, resumeObserver]
    }

    private func removeSessionObservers() {
        guard !sessionObservers.isEmpty else { return }
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sessionObservers.removeAll()
    }

    private func exifOrientation() -> CGImagePropertyOrientation {
        switch outputOrientation {
        case .portrait:
            return outputMirrored ? .upMirrored : .up
        case .portraitUpsideDown:
            return outputMirrored ? .downMirrored : .down
        case .landscapeRight:
            return outputMirrored ? .rightMirrored : .right
        case .landscapeLeft:
            return outputMirrored ? .leftMirrored : .left
        @unknown default:
            return outputMirrored ? .upMirrored : .up
        }
    }

    private func makeComposedImage(from buffer: CVPixelBuffer, targetSize: CGSize) -> CIImage {
        let oriented = CIImage(cvPixelBuffer: buffer).oriented(exifOrientation())
        let normalized = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.origin.x,
                                                                    y: -oriented.extent.origin.y))
        let scaleX = targetSize.width / normalized.extent.width
        let scaleY = targetSize.height / normalized.extent.height
        let scale = min(scaleX, scaleY)
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let origin = CGPoint(x: (targetSize.width - scaled.extent.width) / 2,
                             y: (targetSize.height - scaled.extent.height) / 2)
        let positioned = scaled.transformed(by: CGAffineTransform(translationX: origin.x - scaled.extent.origin.x,
                                                                  y: origin.y - scaled.extent.origin.y))
        let canvas = CGRect(origin: .zero, size: targetSize)
        let background = CIImage(color: .black).cropped(to: canvas)
        return positioned.composited(over: background)
    }

    private func makePreviewImage(from buffer: CVPixelBuffer) -> UIImage? {
        let targetSize = previewTargetSize
        let composed = makeComposedImage(from: buffer, targetSize: targetSize)
        guard let cgImage = context.createCGImage(composed, from: CGRect(origin: .zero, size: targetSize)) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func emitPreviewIfNeeded(from buffer: CVPixelBuffer, now: CFTimeInterval) {
        guard let onPreviewImage else { return }
        if lastPreviewAt != 0, now - lastPreviewAt < 0.12 { return }
        lastPreviewAt = now
        if let image = makePreviewImage(from: buffer) {
            onPreviewImage(image)
        }
    }

    private func encodeFrame(_ buffer: CVPixelBuffer) -> Data? {
        let targetSize = outputTargetSize
        let composed = makeComposedImage(from: buffer, targetSize: targetSize)
        let pixels = max(1, targetSize.width * targetSize.height)
        let bytesPerFrame = Double(targetBitrateKbps) * 1000.0 / 8.0 / max(targetFps, 1)
        let bytesPerPixel = bytesPerFrame / Double(pixels)
        let quality = min(max(bytesPerPixel * 5.2, 0.45), 0.95)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality
        ]
        if let data = context.jpegRepresentation(of: composed, colorSpace: colorSpace, options: options) {
            return data
        }
        guard let cgImage = context.createCGImage(composed, from: composed.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
    }

    private func setupCompressionSessionIfNeeded(forceRecreate: Bool = true) throws {
        let target = outputTargetSize
        let width = Int(target.width)
        let height = Int(target.height)
        if !forceRecreate, let session = compressionSession, width == compressionWidth, height == compressionHeight {
            updateCompressionBitrate()
            return
        }
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        compressionWidth = width
        compressionHeight = height
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                width: Int32(width),
                                                height: Int32(height),
                                                codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: compressionOutputCallback,
                                                refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                                                compressionSessionOut: &session)
        guard status == noErr, let session else { throw StreamError.configurationFailed }
        compressionSession = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        let interval = max(1, Int(targetFps.rounded()))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: interval as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: interval as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        updateCompressionBitrate()
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func updateCompressionBitrate() {
        guard let session = compressionSession else { return }
        let bitrate = max(150_000, targetBitrateKbps * 1000)
        let limit = max(1, bitrate * 2 / 8)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [limit, 1] as CFArray)
    }

    private func makeRenderBuffer(size: CGSize) -> CVPixelBuffer? {
        if renderBufferPool == nil || renderBufferSize != size {
            renderBufferPool = nil
            renderBufferSize = size
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            renderBufferPool = pool
        }
        guard let pool = renderBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    private func encodeH264(_ buffer: CVPixelBuffer, pts: CMTime) {
        guard let session = compressionSession else { return }
        let target = outputTargetSize
        guard let renderBuffer = makeRenderBuffer(size: target) else { return }
        let composed = makeComposedImage(from: buffer, targetSize: target)
        context.render(composed, to: renderBuffer)
        let timescale = CMTimeScale(Int32(max(1, targetFps.rounded())))
        let duration = CMTime(value: 1, timescale: timescale)
        var infoFlags = VTEncodeInfoFlags()
        VTCompressionSessionEncodeFrame(session,
                                        imageBuffer: renderBuffer,
                                        presentationTimeStamp: pts,
                                        duration: duration,
                                        frameProperties: nil,
                                        sourceFrameRefcon: nil,
                                        infoFlagsOut: &infoFlags)
    }

    private let compressionOutputCallback: VTCompressionOutputCallback = { outputRefCon, _, status, flags, sampleBuffer in
        guard status == noErr,
              let sampleBuffer = sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        let stream = Unmanaged<WhisperVideoStream>.fromOpaque(outputRefCon!).takeUnretainedValue()
        stream.handleCompressionOutput(sampleBuffer)
    }

    private func handleCompressionOutput(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var isKeyframe = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            isKeyframe = !notSync
        }
        var output = Data()
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var spsSize = 0
            var spsCount = 0
            var spsPointer: UnsafePointer<UInt8>?
            var ppsSize = 0
            var ppsCount = 0
            var ppsPointer: UnsafePointer<UInt8>?
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
                                                               parameterSetIndex: 0,
                                                               parameterSetPointerOut: &spsPointer,
                                                               parameterSetSizeOut: &spsSize,
                                                               parameterSetCountOut: &spsCount,
                                                               nalUnitHeaderLengthOut: nil)
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
                                                               parameterSetIndex: 1,
                                                               parameterSetPointerOut: &ppsPointer,
                                                               parameterSetSizeOut: &ppsSize,
                                                               parameterSetCountOut: &ppsCount,
                                                               nalUnitHeaderLengthOut: nil)
            if let spsPointer, spsSize > 0 {
                output.append(contentsOf: [0, 0, 0, 1])
                output.append(spsPointer, count: spsSize)
            }
            if let ppsPointer, ppsSize > 0 {
                output.append(contentsOf: [0, 0, 0, 1])
                output.append(ppsPointer, count: ppsSize)
            }
        }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard let dataPointer else { return }
        var bufferOffset = 0
        let headerLength = 4
        while bufferOffset + headerLength <= totalLength {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, dataPointer + bufferOffset, headerLength)
            nalLength = CFSwapInt32BigToHost(nalLength)
            let nalStart = bufferOffset + headerLength
            if nalStart + Int(nalLength) > totalLength { break }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(Data(bytes: dataPointer + nalStart, count: Int(nalLength)))
            bufferOffset = nalStart + Int(nalLength)
        }
        guard !output.isEmpty else { return }
        let target = outputTargetSize
        onFrame?(output, Int(target.width), Int(target.height))
    }
}

extension WhisperVideoStream: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard shouldEmitFrame(now: now) else { return }
        emitPreviewIfNeeded(from: buffer, now: now)
        autoreleasepool {
            switch codecKind {
            case .jpeg:
                if let data = encodeFrame(buffer) {
                    let target = outputTargetSize
                    onFrame?(data, Int(target.width), Int(target.height))
                }
            case .h264:
                if compressionSession == nil {
                    try? setupCompressionSessionIfNeeded()
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                encodeH264(buffer, pts: pts)
            }
        }
    }
}
