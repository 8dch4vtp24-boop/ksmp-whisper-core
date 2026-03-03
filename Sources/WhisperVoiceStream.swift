import AVFoundation
import AudioToolbox
import Foundation
import os.lock

// StreamVoice audio I/O (capture + playback) implemented on top of VoiceProcessingIO/RemoteIO.
//
// The previous AVAudioEngine + tap approach proved unreliable on real devices (capF=0: tap callback never fires)
// across newer iOS versions. AudioUnit is significantly more robust for real-time bidirectional voice.
final class WhisperVoiceStream {
    enum StreamError: Error {
        case noInput
        case audioUnit(OSStatus)
    }

    enum ProcessingMode {
        case voiceChat
        case rawPcm
    }

    var onFrame: ((Data) -> Void)?
    var onInputUnavailable: (() -> Void)?

    private let targetSampleRate: Double
    private let frameBytes: Int
    private let modeOverride: AVAudioSession.Mode?
    private let processingMode: ProcessingMode
    private let prefersLargerPlaybackBuffer: Bool
    // Fixed-point Q15 gain (1.0 == 32768). Applied to PCM samples.
    private let captureGainQ15: Int32
    private let playbackGainQ15: Int32

    // We run the AudioUnit at a stable "IO rate" and resample to/from the target rate.
    // 48 kHz is the most compatible voice rate for iOS hardware.
    private let ioSampleRate: Double = 48_000

    private let captureQueue = DispatchQueue(label: "whisper.voice.capture", qos: .userInteractive)
    private let enqueueQueue = DispatchQueue(label: "whisper.voice.enqueue", qos: .userInteractive)

    private var audioUnit: AudioUnit?
    private var isRunning = false
    private var playbackOnly = false
    private var isUsingVoiceProcessingIO = false

    // MARK: - Playback ring (io-rate Int16 samples)

    private let pbCapacitySamples: Int = 48_000 * 2 // 2 seconds @ 48 kHz
    // Keep playback latency bounded. If the buffer grows above hard max (e.g. due to bursts/lock contention),
    // drop oldest audio down to the target to avoid 2-4s delay.
    // Start low-latency by default; if we ever need adaptive jitter buffering, do it explicitly.
    // Slightly larger target buffer reduces micro dropouts on jittery networks/devices,
    // while still keeping end-to-end latency far from the 2-4s "buffer balloon" failure mode.
    // Keep baseline latency low, but allow short bursts without tearing.
    // Target is where we "trim back to" if the buffer ever balloons over hard max.
    // Keep a slightly larger base buffer now that call stability is the priority, and
    // give PCM lossless mode extra headroom because bursts/network jitter are more audible there.
    private var pbTargetSamples: Int {
        Int(ioSampleRate * (prefersLargerPlaybackBuffer ? 0.14 : 0.11)) // ~140ms (lossless) / ~110ms (default)
    }
    private var pbHardMaxSamples: Int {
        Int(ioSampleRate * (prefersLargerPlaybackBuffer ? 0.44 : 0.36)) // ~440ms (lossless) / ~360ms (default)
    }
    // Small playback hysteresis: after an underrun, wait for a bit of data before resuming
    // so we don't produce an audible "catch" from near-empty buffer state.
    private var pbResumeThresholdSamples: Int {
        max(Int(ioSampleRate * 0.04), Int(Double(pbTargetSamples) * 0.65))
    }
    private var pbBuf: UnsafeMutablePointer<Int16>?
    private var pbRead: Int = 0
    private var pbWrite: Int = 0
    private var pbCount: Int = 0
    private var pbIsPrimed: Bool = false
    private var pbLock = os_unfair_lock_s()
    private var pbDropTotal: Int = 0
    private var pbUnderrunTotal: Int = 0
    private var lastDbgPbDrop: Int = 0
    private var lastDbgPbUnderrun: Int = 0

    // MARK: - Capture ring (target-rate Int16 samples)

    private var capBuf: UnsafeMutablePointer<Int16>?
    private var capCapacitySamples: Int { max(1, (frameBytes / 2) * 50) } // ~1s worth @ 20ms frames
    private var capRead: Int = 0
    private var capWrite: Int = 0
    private var capCount: Int = 0
    private var capLock = os_unfair_lock_s()

    // MARK: - Scratch

    private let inputScratchMaxFrames: UInt32 = 4096
    private var inputScratch: UnsafeMutablePointer<Int16>?
    private var rxScratch: UnsafeMutablePointer<Int16>?
    private var rxScratchCapacity: Int = 0
    private var txScratch: UnsafeMutablePointer<Int16>?
    private var txScratchCapacity: Int = 0

    // MARK: - Controls

    private var isMuted = false
    private var isSpeakerEnabled = false
    private var didNotifyInputUnavailable = false
    private var routeChangeObserver: NSObjectProtocol?

    // MARK: - Debug

    private var debugTimer: DispatchSourceTimer?
    private var capFramesTotal: Int = 0
    private var playFramesTotal: Int = 0
    private var lastDbgCap: Int = 0
    private var lastDbgPlay: Int = 0
    private var capPeakMax: Int = 0
    private var playPeakMax: Int = 0

    init(targetSampleRate: Double = 16_000,
         frameBytes: Int = 640,
         modeOverride: AVAudioSession.Mode? = nil,
         processingMode: ProcessingMode = .voiceChat,
         prefersLargerPlaybackBuffer: Bool = false,
         captureGain: Double = 1.0,
         playbackGain: Double = 1.0) {
        self.targetSampleRate = targetSampleRate
        self.frameBytes = frameBytes
        self.modeOverride = modeOverride
        self.processingMode = processingMode
        self.prefersLargerPlaybackBuffer = prefersLargerPlaybackBuffer
        self.captureGainQ15 = WhisperVoiceStream.gainToQ15(captureGain)
        self.playbackGainQ15 = WhisperVoiceStream.gainToQ15(playbackGain)
    }

    deinit {
        stop()
        pbBuf?.deallocate()
        capBuf?.deallocate()
        inputScratch?.deallocate()
        rxScratch?.deallocate()
        txScratch?.deallocate()
    }

    func start() throws {
        guard !isRunning else { return }

        try prepareAudioSession()
        startRouteChangeObserverIfNeeded()

        if pbBuf == nil {
            pbBuf = .allocate(capacity: pbCapacitySamples)
        }
        if capBuf == nil {
            capBuf = .allocate(capacity: capCapacitySamples)
        }
        if inputScratch == nil {
            inputScratch = .allocate(capacity: Int(inputScratchMaxFrames))
        }
        ensureRxScratchCapacity(samples: Int(inputScratchMaxFrames) * 3)
        ensureTxScratchCapacity(samples: Int(inputScratchMaxFrames))

        clearRings()

        let unit = try createAndConfigureAudioUnit()
        audioUnit = unit

        let statusInit = AudioUnitInitialize(unit)
        guard statusInit == noErr else { throw StreamError.audioUnit(statusInit) }

        let statusStart = AudioOutputUnitStart(unit)
        guard statusStart == noErr else { throw StreamError.audioUnit(statusStart) }

        isRunning = true

        if StreamVoiceDebug.isEnabled {
            let session = AVAudioSession.sharedInstance()
            let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
            let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
            let pm = (processingMode == .rawPcm) ? "rawPcm" : "voiceChat"
            let au = isUsingVoiceProcessingIO ? "vpio" : "remoteio"
            let hwSR = Int(session.sampleRate.rounded())
            let ioBufMs = Int((session.ioBufferDuration * 1000.0).rounded())
            StreamVoiceDebug.log("au start ioSR=\(Int(ioSampleRate)) targetSR=\(Int(targetSampleRate)) hwSR=\(hwSR) ioBufMs=\(ioBufMs) frameB=\(frameBytes) pm=\(pm) au=\(au) playbackOnly=\(playbackOnly) out=\(outputs) in=\(inputs) cat=\(session.category.rawValue) mode=\(session.mode.rawValue) outVol=\(session.outputVolume)")
        }

        if StreamVoiceDebug.isEnabled {
            startDebugTimerIfNeeded()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        stopRouteChangeObserver()
        stopDebugTimer()

        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil

        clearRings()
        didNotifyInputUnavailable = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        isSpeakerEnabled = enabled
        applySpeakerOverrideIfNeeded()
        // If we're already running, re-prepare session (route can affect mode).
        if isRunning {
            try? prepareAudioSession()
        }
    }

    // Incoming network audio (PCM16 at targetSampleRate).
    func handleFrame(_ data: Data) {
        guard !data.isEmpty else { return }
        enqueueQueue.async { [weak self] in
            guard let self else { return }
            // Fast path: no resampling needed.
            if abs(self.targetSampleRate - self.ioSampleRate) < 1 {
                data.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
                    let count = raw.count / MemoryLayout<Int16>.size
                    self.pushPlaybackPtr(base, count: count)
                }
                return
            }
            // Hot path: 16k PCM16 -> 48k IO (x3). Avoid intermediate arrays.
            if abs(self.ioSampleRate - 48_000) < 1, abs(self.targetSampleRate - 16_000) < 1 {
                data.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
                    let inCount = raw.count / MemoryLayout<Int16>.size
                    self.pushPlaybackUpsample16To48(src: base, count: inCount)
                }
                return
            }

            // Fallback: allocate/convert.
            let pcm = self.decodePCM16(data)
            guard !pcm.isEmpty else { return }
            let ioSamples = self.resampleToIO(pcm)
            self.pushPlayback(ioSamples)
        }
    }

    // MARK: - Session

    private func prepareAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        // Determine record permission in a forward-compatible way.
        let permissionGranted: Bool = {
            if #available(iOS 17.0, *) {
                return AVAudioApplication.shared.recordPermission == .granted
            } else {
                return session.recordPermission == .granted
            }
        }()

        var options: AVAudioSession.CategoryOptions = {
            switch processingMode {
            case .rawPcm:
                // Avoid Bluetooth HFP (narrow-band / "phone" audio). If the user wants raw/lossless PCM,
                // we prioritize fidelity and predictability over headset mic support.
                return [.allowBluetoothA2DP]
            case .voiceChat:
                return [.allowBluetooth]
            }
        }()
        if isSpeakerEnabled {
            options.insert(.defaultToSpeaker)
        }

        try? session.setCategory(.playAndRecord, options: options)
        try? session.setPreferredSampleRate(ioSampleRate)
        // Smaller buffers reduce end-to-end latency; system may clamp this value.
        try? session.setPreferredIOBufferDuration(preferredIOBufferDuration())

        let mode: AVAudioSession.Mode = {
            if let modeOverride { return modeOverride }
            switch processingMode {
            case .rawPcm:
                // On some routes/devices, `.measurement` can sound oddly band-limited.
                // Prefer `.default` for speaker/headphones (best perceived fidelity),
                // and use `.measurement` primarily to suppress sidetone when not on speaker.
                return isSpeakerEnabled ? .default : .measurement
            case .voiceChat:
                return .voiceChat
            }
        }()
        try? session.setMode(mode)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // Prefer wired/USB mics over the built-in mic (e.g. lavalier), but never auto-prefer Bluetooth.
        // Bluetooth HFP can sound "low bitrate" (band-limited) and may surprise users.
        applyPreferredInputIfNeeded(reason: "prepare")

        applySpeakerOverrideIfNeeded()

        // Compute playbackOnly after activating the session, so currentRoute is up-to-date.
        playbackOnly = session.currentRoute.inputs.isEmpty || !session.isInputAvailable || !permissionGranted
        if playbackOnly {
            notifyInputUnavailableIfNeeded()
        }
    }

    private func startRouteChangeObserverIfNeeded() {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.isRunning else { return }
            // Re-apply preferred input dynamically (e.g. user plugs in a lavalier during a call).
            self.applyPreferredInputIfNeeded(reason: "routeChange")
        }
    }

    private func stopRouteChangeObserver() {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        routeChangeObserver = nil
    }

    private func applyPreferredInputIfNeeded(reason: String) {
        let session = AVAudioSession.sharedInstance()
        guard let inputs = session.availableInputs, !inputs.isEmpty else { return }

        // Prefer external wired/USB mics. If none, keep/allow built-in.
        let preferred = inputs.first(where: { $0.portType == .usbAudio }) ??
            inputs.first(where: { $0.portType == .headsetMic }) ??
            inputs.first(where: { $0.portType == .lineIn }) ??
            inputs.first(where: { $0.portType == .builtInMic })

        guard let preferred else { return }
        guard session.preferredInput?.uid != preferred.uid else { return }

        do {
            try session.setPreferredInput(preferred)
            if StreamVoiceDebug.isEnabled {
                StreamVoiceDebug.log("au prefer input=\(preferred.portType.rawValue) reason=\(reason)")
            }
        } catch {
            if StreamVoiceDebug.isEnabled {
                StreamVoiceDebug.log("au prefer input FAILED reason=\(reason) err=\(String(describing: error))")
            }
        }
    }

    private func applySpeakerOverrideIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map(\.portType)
        let hasExternal = outputs.contains {
            $0 == .headphones ||
            $0 == .bluetoothA2DP ||
            $0 == .bluetoothLE ||
            $0 == .bluetoothHFP ||
            $0 == .usbAudio ||
            $0 == .lineOut ||
            $0 == .airPlay ||
            $0 == .carAudio
        }
        guard !hasExternal else { return }
        do {
            try session.overrideOutputAudioPort(isSpeakerEnabled ? .speaker : .none)
        } catch {
            // ignore
        }
    }

    private func notifyInputUnavailableIfNeeded() {
        guard !didNotifyInputUnavailable else { return }
        didNotifyInputUnavailable = true
        DispatchQueue.main.async { [weak self] in
            self?.onInputUnavailable?()
        }
    }

    // MARK: - AudioUnit setup

    private func createAndConfigureAudioUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        // In raw PCM mode, prefer RemoteIO to avoid any voice processing pipeline entirely.
        if processingMode == .rawPcm {
            desc.componentSubType = kAudioUnitSubType_RemoteIO
            if let remote = AudioComponentFindNext(nil, &desc) {
                isUsingVoiceProcessingIO = false
                return try instantiateAndConfigure(component: remote, usesVPIO: false)
            }
            // Fall back to VoiceProcessingIO if RemoteIO is unavailable (shouldn't happen on iOS).
            desc.componentSubType = kAudioUnitSubType_VoiceProcessingIO
        }

        guard let comp = AudioComponentFindNext(nil, &desc) else {
            // Fallback to RemoteIO.
            desc.componentSubType = kAudioUnitSubType_RemoteIO
            guard let remote = AudioComponentFindNext(nil, &desc) else {
                throw StreamError.audioUnit(-1)
            }
            isUsingVoiceProcessingIO = false
            return try instantiateAndConfigure(component: remote, usesVPIO: false)
        }
        isUsingVoiceProcessingIO = (desc.componentSubType == kAudioUnitSubType_VoiceProcessingIO)
        return try instantiateAndConfigure(component: comp, usesVPIO: isUsingVoiceProcessingIO)
    }

    private func instantiateAndConfigure(component: AudioComponent, usesVPIO: Bool) throws -> AudioUnit {
        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else { throw StreamError.audioUnit(status) }

        // Enable IO.
        var one: UInt32 = 1
        var zero: UInt32 = 0
        if playbackOnly {
            status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, UInt32(MemoryLayout<UInt32>.size))
            guard status == noErr else { throw StreamError.audioUnit(status) }
        } else {
            status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size))
            guard status == noErr else { throw StreamError.audioUnit(status) }
        }
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw StreamError.audioUnit(status) }

        // Stream formats.
        var asbd = ioASBD()
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw StreamError.audioUnit(status) }
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw StreamError.audioUnit(status) }

        // Render callbacks.
        var render = AURenderCallbackStruct(inputProc: Self.renderCallback, inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &render, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw StreamError.audioUnit(status) }

        if !playbackOnly {
            var inputCb = AURenderCallbackStruct(inputProc: Self.inputCallback, inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
            status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &inputCb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard status == noErr else { throw StreamError.audioUnit(status) }
        }

        // VoiceProcessingIO tuning (best-effort).
        if usesVPIO {
            switch processingMode {
            case .rawPcm:
                // Disable built-in voice processing/AGC for raw PCM mode.
                var bypass: UInt32 = 1
                _ = AudioUnitSetProperty(unit, kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global, 0, &bypass, UInt32(MemoryLayout<UInt32>.size))
                var agc: UInt32 = 0
                _ = AudioUnitSetProperty(unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0, &agc, UInt32(MemoryLayout<UInt32>.size))
            case .voiceChat:
                var bypass: UInt32 = 0
                _ = AudioUnitSetProperty(unit, kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global, 0, &bypass, UInt32(MemoryLayout<UInt32>.size))
            }
        }

        // Larger max frames helps avoid -1/-10868 style issues when the system picks a larger slice.
        var maxFrames: UInt32 = inputScratchMaxFrames
        _ = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))

        return unit
    }

    private func ioASBD() -> AudioStreamBasicDescription {
        let bytesPerFrame: UInt32 = 2
        return AudioStreamBasicDescription(
            mSampleRate: ioSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    // MARK: - Callbacks

    private static let renderCallback: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
        guard let ioData else { return noErr }
        let stream = Unmanaged<WhisperVoiceStream>.fromOpaque(inRefCon).takeUnretainedValue()
        return stream.renderOutput(inNumberFrames: inNumberFrames, ioData: ioData)
    }

    private static let inputCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
        let stream = Unmanaged<WhisperVoiceStream>.fromOpaque(inRefCon).takeUnretainedValue()
        return stream.captureInput(ioActionFlags: ioActionFlags,
                                   inTimeStamp: inTimeStamp,
                                   inBusNumber: inBusNumber,
                                   inNumberFrames: inNumberFrames)
    }

    private func renderOutput(inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard isRunning else {
            zero(ioData, frames: inNumberFrames)
            return noErr
        }
        // Single mono buffer.
        let nSamples = Int(inNumberFrames)
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        guard let buf = abl.first, let mData = buf.mData else {
            return noErr
        }
        let out = mData.bindMemory(to: Int16.self, capacity: nSamples)

        // Read from playback ring. The critical section is just memcpy + index updates.
        // Using trylock here caused occasional full-buffer zeros (audible dropouts) under contention.
        os_unfair_lock_lock(&pbLock)

        if !pbIsPrimed, pbCount >= pbResumeThresholdSamples {
            pbIsPrimed = true
        }

        let toRead = pbIsPrimed ? min(nSamples, pbCount) : 0
        if toRead > 0, let pbBuf {
            let first = min(toRead, pbCapacitySamples - pbRead)
            memcpy(out, pbBuf.advanced(by: pbRead), first * MemoryLayout<Int16>.size)
            let remain = toRead - first
            if remain > 0 {
                memcpy(out.advanced(by: first), pbBuf, remain * MemoryLayout<Int16>.size)
            }
            if StreamVoiceDebug.isEnabled {
                var peak = 0
                for i in 0..<toRead {
                    let s = out[i]
                    let v = s == Int16.min ? Int(Int16.max) : abs(Int(s))
                    if v > peak { peak = v }
                }
                playPeakMax = max(playPeakMax, peak)
            }
            pbRead = (pbRead + toRead) % pbCapacitySamples
            pbCount -= toRead
            if toRead < nSamples {
                pbIsPrimed = false
                if StreamVoiceDebug.isEnabled { pbUnderrunTotal += 1 }
            }
        }
        os_unfair_lock_unlock(&pbLock)

        if toRead > 0, playbackGainQ15 != 32768 {
            applyGainQ15(out, count: toRead, gainQ15: playbackGainQ15)
        }
        if toRead < nSamples {
            memset(out.advanced(by: toRead), 0, (nSamples - toRead) * MemoryLayout<Int16>.size)
        }
        playFramesTotal += 1
        return noErr
    }

    private func captureInput(ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                              inTimeStamp: UnsafePointer<AudioTimeStamp>,
                              inBusNumber: UInt32,
                              inNumberFrames: UInt32) -> OSStatus {
        guard isRunning else { return noErr }
        guard !playbackOnly else { return noErr }
        guard let unit = audioUnit else { return noErr }
        guard let scratch = inputScratch else { return noErr }

        // Prepare an AudioBufferList pointing to our scratch.
        var buffer = AudioBuffer(mNumberChannels: 1,
                                 mDataByteSize: inNumberFrames * 2,
                                 mData: scratch)
        var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)

        let status = AudioUnitRender(unit,
                                     ioActionFlags,
                                     inTimeStamp,
                                     1,
                                     inNumberFrames,
                                     &bufferList)
        guard status == noErr else { return status }

        let inSamples = Int(inNumberFrames)
        let input = UnsafeBufferPointer(start: scratch, count: inSamples)
        // Fast path: no resampling required.
        if abs(targetSampleRate - ioSampleRate) < 1 {
            pushCaptureFromIO(input, muted: isMuted)
        }
        // Hot path: 48k IO -> 16k (drop 2/3). Avoid allocating a new [Int16] per callback.
        else if abs(ioSampleRate - 48_000) < 1, abs(targetSampleRate - 16_000) < 1 {
            pushCaptureDecimate48To16(input, muted: isMuted)
        } else {
            var pcm: [Int16] = []
            pcm.reserveCapacity(inSamples)
            if isMuted {
                pcm = Array(repeating: 0, count: resampledCountFromIO(inSamples))
            } else {
                pcm = resampleFromIO(input)
            }
            pushCapture(pcm)
        }
        capFramesTotal += 1
        return noErr
    }

    // MARK: - Ring ops

    private func clearRings() {
        os_unfair_lock_lock(&pbLock)
        pbRead = 0
        pbWrite = 0
        pbCount = 0
        pbIsPrimed = false
        os_unfair_lock_unlock(&pbLock)

        os_unfair_lock_lock(&capLock)
        capRead = 0
        capWrite = 0
        capCount = 0
        os_unfair_lock_unlock(&capLock)
    }

    private func pushPlayback(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        os_unfair_lock_lock(&pbLock)
        defer { os_unfair_lock_unlock(&pbLock) }
        guard let pbBuf else { return }

        var incomingCount = samples.count
        if incomingCount >= pbCapacitySamples {
            // If something went very wrong, keep only the tail that fits.
            incomingCount = pbCapacitySamples
        }

        let free = pbCapacitySamples - pbCount
        if incomingCount > free {
            // Drop oldest to make room (prefer latest voice).
            let need = incomingCount - free
            pbRead = (pbRead + need) % pbCapacitySamples
            pbCount = max(0, pbCount - need)
            if StreamVoiceDebug.isEnabled { pbDropTotal += need }
        }

        samples.withUnsafeBufferPointer { src in
            guard let srcBase = src.baseAddress else { return }
            let first = min(incomingCount, pbCapacitySamples - pbWrite)
            memcpy(pbBuf.advanced(by: pbWrite), srcBase, first * MemoryLayout<Int16>.size)
            let remain = incomingCount - first
            if remain > 0 {
                memcpy(pbBuf, srcBase.advanced(by: first), remain * MemoryLayout<Int16>.size)
            }
        }

        pbWrite = (pbWrite + incomingCount) % pbCapacitySamples
        pbCount = min(pbCapacitySamples, pbCount + incomingCount)

        // Latency clamp: if buffer has grown too large, drop oldest down to target.
        if pbCount > pbHardMaxSamples {
            let drop = pbCount - pbTargetSamples
            if drop > 0 {
                pbRead = (pbRead + drop) % pbCapacitySamples
                pbCount = max(0, pbCount - drop)
                if StreamVoiceDebug.isEnabled { pbDropTotal += drop }
            }
        }
    }

    private func pushPlaybackPtr(_ src: UnsafePointer<Int16>, count: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(&pbLock)
        defer { os_unfair_lock_unlock(&pbLock) }
        guard let pbBuf else { return }

        var incomingCount = count
        if incomingCount >= pbCapacitySamples {
            incomingCount = pbCapacitySamples
        }

        let free = pbCapacitySamples - pbCount
        if incomingCount > free {
            let need = incomingCount - free
            pbRead = (pbRead + need) % pbCapacitySamples
            pbCount = max(0, pbCount - need)
            if StreamVoiceDebug.isEnabled { pbDropTotal += need }
        }

        let first = min(incomingCount, pbCapacitySamples - pbWrite)
        memcpy(pbBuf.advanced(by: pbWrite), src, first * MemoryLayout<Int16>.size)
        let remain = incomingCount - first
        if remain > 0 {
            memcpy(pbBuf, src.advanced(by: first), remain * MemoryLayout<Int16>.size)
        }

        pbWrite = (pbWrite + incomingCount) % pbCapacitySamples
        pbCount = min(pbCapacitySamples, pbCount + incomingCount)

        if pbCount > pbHardMaxSamples {
            let drop = pbCount - pbTargetSamples
            if drop > 0 {
                pbRead = (pbRead + drop) % pbCapacitySamples
                pbCount = max(0, pbCount - drop)
                if StreamVoiceDebug.isEnabled { pbDropTotal += drop }
            }
        }
    }

    private func pushCapture(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        // Write samples into capture ring (target-rate).
        os_unfair_lock_lock(&capLock)
        guard let capBuf else {
            os_unfair_lock_unlock(&capLock)
            return
        }
        let free = capCapacitySamples - capCount
        if samples.count > free {
            // Drop oldest (capture is for sending realtime).
            let need = samples.count - free
            capRead = (capRead + need) % capCapacitySamples
            capCount = max(0, capCount - need)
        }
        if StreamVoiceDebug.isEnabled {
            var peak = 0
            for s in samples {
                capBuf[capWrite] = s
                let v = s == Int16.min ? Int(Int16.max) : abs(Int(s))
                if v > peak { peak = v }
                capWrite += 1
                if capWrite == capCapacitySamples { capWrite = 0 }
            }
            capPeakMax = max(capPeakMax, peak)
        } else {
            // Copy without computing peaks.
            samples.withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress else { return }
                let first = min(samples.count, capCapacitySamples - capWrite)
                memcpy(capBuf.advanced(by: capWrite), srcBase, first * MemoryLayout<Int16>.size)
                let remain = samples.count - first
                if remain > 0 {
                    memcpy(capBuf, srcBase.advanced(by: first), remain * MemoryLayout<Int16>.size)
                }
                capWrite = (capWrite + samples.count) % capCapacitySamples
            }
        }
        capCount = min(capCapacitySamples, capCount + samples.count)

        // Pop frames for network on a non-realtime queue.
        let frameSamples = frameBytes / 2
        let canPop = capCount >= frameSamples
        os_unfair_lock_unlock(&capLock)
        guard canPop else { return }

        captureQueue.async { [weak self] in
            self?.drainCaptureFrames()
        }
    }

    private func drainCaptureFrames() {
        let frameSamples = frameBytes / 2
        // Avoid spending too long draining (called often).
        var drained = 0
        while drained < 4 {
            os_unfair_lock_lock(&capLock)
            guard capCount >= frameSamples, let capBuf else {
                os_unfair_lock_unlock(&capLock)
                return
            }
            var frame = Data(count: frameBytes)
            frame.withUnsafeMutableBytes { raw in
                guard let out = raw.bindMemory(to: Int16.self).baseAddress else { return }
                let first = min(frameSamples, capCapacitySamples - capRead)
                memcpy(out, capBuf.advanced(by: capRead), first * MemoryLayout<Int16>.size)
                let remain = frameSamples - first
                if remain > 0 {
                    memcpy(out.advanced(by: first), capBuf, remain * MemoryLayout<Int16>.size)
                }
            }
            capRead = (capRead + frameSamples) % capCapacitySamples
            capCount -= frameSamples
            os_unfair_lock_unlock(&capLock)
            onFrame?(frame)
            drained += 1
        }
    }

    private func pushPlaybackUpsample16To48(src: UnsafePointer<Int16>, count: Int) {
        guard count > 0 else { return }
        let outCount = count * 3
        ensureRxScratchCapacity(samples: outCount)
        guard let scratch = rxScratch else { return }
        var j = 0
        for i in 0..<count {
            let s = src[i]
            scratch[j] = s
            scratch[j + 1] = s
            scratch[j + 2] = s
            j += 3
        }
        pushPlaybackPtr(scratch, count: outCount)
    }

    private func pushCaptureFromIO(_ input: UnsafeBufferPointer<Int16>, muted: Bool) {
        let count = input.count
        guard count > 0 else { return }

        // Write IO-rate samples into capture ring (target-rate == IO-rate).
        os_unfair_lock_lock(&capLock)
        guard let capBuf else {
            os_unfair_lock_unlock(&capLock)
            return
        }

        let free = capCapacitySamples - capCount
        if count > free {
            let need = count - free
            capRead = (capRead + need) % capCapacitySamples
            capCount = max(0, capCount - need)
        }

        if muted {
            let first = min(count, capCapacitySamples - capWrite)
            memset(capBuf.advanced(by: capWrite), 0, first * MemoryLayout<Int16>.size)
            let remain = count - first
            if remain > 0 {
                memset(capBuf, 0, remain * MemoryLayout<Int16>.size)
            }
            capWrite = (capWrite + count) % capCapacitySamples
        } else if captureGainQ15 == 32768 {
            // Straight copy.
            guard let srcBase = input.baseAddress else {
                os_unfair_lock_unlock(&capLock)
                return
            }
            let first = min(count, capCapacitySamples - capWrite)
            memcpy(capBuf.advanced(by: capWrite), srcBase, first * MemoryLayout<Int16>.size)
            let remain = count - first
            if remain > 0 {
                memcpy(capBuf, srcBase.advanced(by: first), remain * MemoryLayout<Int16>.size)
            }
            capWrite = (capWrite + count) % capCapacitySamples
            if StreamVoiceDebug.isEnabled {
                // Debug-only: keep a rough peak so logs are meaningful even at gain=1.0.
                // Use a stride to avoid heavy scanning on very small IO buffers.
                var peak = 0
                var i = 0
                while i < count {
                    let s = srcBase[i]
                    let v = s == Int16.min ? Int(Int16.max) : abs(Int(s))
                    if v > peak { peak = v }
                    i += 8
                }
                capPeakMax = max(capPeakMax, peak)
            }
        } else {
            // Apply gain while copying.
            var peak = 0
            let first = min(count, capCapacitySamples - capWrite)
            for i in 0..<first {
                let v = applyGainSampleQ15(input[i], gainQ15: captureGainQ15)
                capBuf[capWrite + i] = v
                if StreamVoiceDebug.isEnabled {
                    let av = v == Int16.min ? Int(Int16.max) : abs(Int(v))
                    if av > peak { peak = av }
                }
            }
            let remain = count - first
            if remain > 0 {
                for j in 0..<remain {
                    let v = applyGainSampleQ15(input[first + j], gainQ15: captureGainQ15)
                    capBuf[j] = v
                    if StreamVoiceDebug.isEnabled {
                        let av = v == Int16.min ? Int(Int16.max) : abs(Int(v))
                        if av > peak { peak = av }
                    }
                }
            }
            capWrite = (capWrite + count) % capCapacitySamples
            if StreamVoiceDebug.isEnabled {
                capPeakMax = max(capPeakMax, peak)
            }
        }

        capCount = min(capCapacitySamples, capCount + count)

        let frameSamples = frameBytes / 2
        let canPop = capCount >= frameSamples
        os_unfair_lock_unlock(&capLock)
        if canPop {
            captureQueue.async { [weak self] in
                self?.drainCaptureFrames()
            }
        }
    }

    private func pushCaptureDecimate48To16(_ input: UnsafeBufferPointer<Int16>, muted: Bool) {
        let inCount = input.count
        guard inCount > 0 else { return }
        let outCount = inCount / 3
        guard outCount > 0 else { return }

        ensureTxScratchCapacity(samples: outCount)
        guard let scratch = txScratch else { return }
        if muted {
            memset(scratch, 0, outCount * MemoryLayout<Int16>.size)
        } else {
            var j = 0
            var i = 0
            while j < outCount {
                let s = input[i]
                scratch[j] = (captureGainQ15 == 32768) ? s : applyGainSampleQ15(s, gainQ15: captureGainQ15)
                j += 1
                i += 3
            }
        }

        // Write scratch into capture ring quickly.
        os_unfair_lock_lock(&capLock)
        guard let capBuf else {
            os_unfair_lock_unlock(&capLock)
            return
        }
        let free = capCapacitySamples - capCount
        if outCount > free {
            let need = outCount - free
            capRead = (capRead + need) % capCapacitySamples
            capCount = max(0, capCount - need)
        }
        let first = min(outCount, capCapacitySamples - capWrite)
        memcpy(capBuf.advanced(by: capWrite), scratch, first * MemoryLayout<Int16>.size)
        let remain = outCount - first
        if remain > 0 {
            memcpy(capBuf, scratch.advanced(by: first), remain * MemoryLayout<Int16>.size)
        }
        capWrite = (capWrite + outCount) % capCapacitySamples
        capCount = min(capCapacitySamples, capCount + outCount)

        if StreamVoiceDebug.isEnabled {
            var peak = 0
            for k in 0..<outCount {
                let s = scratch[k]
                let v = s == Int16.min ? Int(Int16.max) : abs(Int(s))
                if v > peak { peak = v }
            }
            capPeakMax = max(capPeakMax, peak)
        }

        let frameSamples = frameBytes / 2
        let canPop = capCount >= frameSamples
        os_unfair_lock_unlock(&capLock)
        if canPop {
            captureQueue.async { [weak self] in
                self?.drainCaptureFrames()
            }
        }
    }

    // MARK: - Resampling

    private func resampleFromIO(_ input: UnsafeBufferPointer<Int16>) -> [Int16] {
        // ioSampleRate -> targetSampleRate
        if abs(targetSampleRate - ioSampleRate) < 1 {
            return Array(input)
        }
        // Common case: 48k -> 16k (factor 3).
        if abs(ioSampleRate - 48_000) < 1, abs(targetSampleRate - 16_000) < 1 {
            let outCount = input.count / 3
            var out: [Int16] = Array(repeating: 0, count: outCount)
            var j = 0
            var i = 0
            while j < outCount {
                out[j] = input[i]
                j += 1
                i += 3
            }
            return out
        }
        // Fallback: linear resample.
        let ratio = targetSampleRate / ioSampleRate
        let outCount = max(1, Int(Double(input.count) * ratio))
        var out: [Int16] = Array(repeating: 0, count: outCount)
        for j in 0..<outCount {
            let pos = Double(j) / ratio
            let i0 = min(input.count - 1, max(0, Int(pos)))
            let i1 = min(input.count - 1, i0 + 1)
            let t = Float(pos - Double(i0))
            let s0 = Float(input[i0])
            let s1 = Float(input[i1])
            out[j] = Int16(max(-Float(Int16.max), min(Float(Int16.max), s0 + (s1 - s0) * t)))
        }
        return out
    }

    private func resampleToIO(_ input: [Int16]) -> [Int16] {
        // targetSampleRate -> ioSampleRate
        if abs(targetSampleRate - ioSampleRate) < 1 {
            return input
        }
        // Common case: 16k -> 48k (factor 3) for PCM.
        if abs(ioSampleRate - 48_000) < 1, abs(targetSampleRate - 16_000) < 1 {
            var out: [Int16] = []
            out.reserveCapacity(input.count * 3)
            for s in input {
                out.append(s)
                out.append(s)
                out.append(s)
            }
            return out
        }
        // Fallback: linear resample.
        let ratio = ioSampleRate / targetSampleRate
        let outCount = max(1, Int(Double(input.count) * ratio))
        var out: [Int16] = Array(repeating: 0, count: outCount)
        for j in 0..<outCount {
            let pos = Double(j) / ratio
            let i0 = min(input.count - 1, max(0, Int(pos)))
            let i1 = min(input.count - 1, i0 + 1)
            let t = Float(pos - Double(i0))
            let s0 = Float(input[i0])
            let s1 = Float(input[i1])
            out[j] = Int16(max(-Float(Int16.max), min(Float(Int16.max), s0 + (s1 - s0) * t)))
        }
        return out
    }

    private func resampledCountFromIO(_ inSamples: Int) -> Int {
        if abs(targetSampleRate - ioSampleRate) < 1 { return inSamples }
        if abs(ioSampleRate - 48_000) < 1, abs(targetSampleRate - 16_000) < 1 { return inSamples / 3 }
        return max(1, Int(Double(inSamples) * (targetSampleRate / ioSampleRate)))
    }

    private func decodePCM16(_ data: Data) -> [Int16] {
        guard !data.isEmpty else { return [] }
        return data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return [] }
            let count = raw.count / MemoryLayout<Int16>.size
            return Array(UnsafeBufferPointer(start: base, count: count))
        }
    }

    private func frameDurationIO() -> TimeInterval {
        let targetSamples = frameBytes / 2
        guard targetSampleRate > 0 else { return 0.02 }
        let seconds = Double(targetSamples) / targetSampleRate
        return max(0.005, min(0.05, seconds))
    }

    private func preferredIOBufferDuration() -> TimeInterval {
        // Prefer small IO buffers for low end-to-end latency; system may clamp.
        //
        // We still packetize network media at 20ms, but smaller hardware buffers reduce
        // device-side latency (AudioUnit scheduling + capture/playback).
        switch processingMode {
        case .rawPcm:
            // 5ms is a good low-latency target across devices; may clamp higher on some routes.
            return 0.005
        case .voiceChat:
            // Keep smaller buffers for interactive voice chat; system may clamp.
            return 0.01
        }
    }

    // MARK: - Helpers

    private func zero(_ ioData: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) {
        let n = Int(frames)
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        for buf in abl {
            guard let mData = buf.mData else { continue }
            let out = mData.bindMemory(to: Int16.self, capacity: n)
            memset(out, 0, n * MemoryLayout<Int16>.size)
        }
    }

    private static func gainToQ15(_ gain: Double) -> Int32 {
        // Clamp to a sane range.
        let g = max(0.0, min(2.0, gain))
        return Int32((g * 32768.0).rounded())
    }

    private func applyGainQ15(_ buf: UnsafeMutablePointer<Int16>, count: Int, gainQ15: Int32) {
        guard count > 0 else { return }
        for i in 0..<count {
            buf[i] = applyGainSampleQ15(buf[i], gainQ15: gainQ15)
        }
    }

    private func applyGainSampleQ15(_ s: Int16, gainQ15: Int32) -> Int16 {
        let v = Int64(s)
        let g = Int64(gainQ15)
        let prod = v * g
        // Symmetric rounding to reduce low-level distortion ("steppy" quiet sounds).
        let rounded = prod + (prod >= 0 ? (1 << 14) : -(1 << 14))
        let scaled = rounded >> 15
        if scaled > Int32(Int16.max) { return Int16.max }
        if scaled < Int32(Int16.min) { return Int16.min }
        return Int16(Int32(scaled))
    }

    // MARK: - Debug

    private func startDebugTimerIfNeeded() {
        guard debugTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let capDelta = self.capFramesTotal - self.lastDbgCap
            let playDelta = self.playFramesTotal - self.lastDbgPlay
            self.lastDbgCap = self.capFramesTotal
            self.lastDbgPlay = self.playFramesTotal

            os_unfair_lock_lock(&self.pbLock)
            let pb = self.pbCount
            let pbDrop = self.pbDropTotal
            let pbUnd = self.pbUnderrunTotal
            os_unfair_lock_unlock(&self.pbLock)

            os_unfair_lock_lock(&self.capLock)
            let cb = self.capCount
            os_unfair_lock_unlock(&self.capLock)

            let session = AVAudioSession.sharedInstance()
            let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
            let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")

            let pbMs = Int((Double(pb) / self.ioSampleRate) * 1000.0)
            let pbDropDelta = pbDrop - self.lastDbgPbDrop
            self.lastDbgPbDrop = pbDrop
            let pbUndDelta = pbUnd - self.lastDbgPbUnderrun
            self.lastDbgPbUnderrun = pbUnd
            StreamVoiceDebug.log("au dbg 2s: capCb+\(capDelta) playCb+\(playDelta) capPeak=\(self.capPeakMax) playPeak=\(self.playPeakMax) pbS=\(pb) pbMs=\(pbMs) pbDrop+\(pbDropDelta) pbUnd+\(pbUndDelta) capS=\(cb) running=\(self.isRunning) playbackOnly=\(self.playbackOnly) muted=\(self.isMuted) speaker=\(self.isSpeakerEnabled) out=\(outputs) in=\(inputs) cat=\(session.category.rawValue) mode=\(session.mode.rawValue) outVol=\(session.outputVolume)")
            self.capPeakMax = 0
            self.playPeakMax = 0
        }
        debugTimer = timer
        timer.resume()
    }

    private func stopDebugTimer() {
        debugTimer?.cancel()
        debugTimer = nil
        capFramesTotal = 0
        playFramesTotal = 0
        lastDbgCap = 0
        lastDbgPlay = 0
        lastDbgPbDrop = 0
        capPeakMax = 0
        playPeakMax = 0
    }

    // MARK: - Scratch management

    private func ensureRxScratchCapacity(samples: Int) {
        guard samples > 0 else { return }
        if rxScratch == nil || rxScratchCapacity < samples {
            rxScratch?.deallocate()
            rxScratch = .allocate(capacity: samples)
            rxScratchCapacity = samples
        }
    }

    private func ensureTxScratchCapacity(samples: Int) {
        guard samples > 0 else { return }
        if txScratch == nil || txScratchCapacity < samples {
            txScratch?.deallocate()
            txScratch = .allocate(capacity: samples)
            txScratchCapacity = samples
        }
    }
}
