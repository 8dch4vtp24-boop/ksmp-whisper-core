import AVFoundation
import AudioToolbox
import Foundation

final class WhisperOpusCodec {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let encoder: AVAudioConverter
    private let decoder: AVAudioConverter
    private let maxPacketSize: Int
    private let frameCapacity: AVAudioFrameCount

    init?(sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1, bitrate: Int = 32_000) {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                        sampleRate: sampleRate,
                                        channels: channels,
                                        interleaved: false) else { return nil }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate
        ]
        guard let output = AVAudioFormat(settings: outputSettings) else { return nil }
        guard let encoder = AVAudioConverter(from: input, to: output),
              let decoder = AVAudioConverter(from: output, to: input) else { return nil }
        self.inputFormat = input
        self.outputFormat = output
        self.encoder = encoder
        self.decoder = decoder
        self.maxPacketSize = max(encoder.maximumOutputPacketSize, 256)
        let frames = Int((sampleRate * 0.02).rounded())
        self.frameCapacity = AVAudioFrameCount(max(frames, 160))
    }

    func encode(_ pcmData: Data) -> Data? {
        let samples = pcmData.count / MemoryLayout<Int16>.size
        guard samples > 0 else { return nil }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                               frameCapacity: AVAudioFrameCount(samples)) else { return nil }
        pcmBuffer.frameLength = AVAudioFrameCount(samples)
        pcmData.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Int16.self).baseAddress,
                  let channel = pcmBuffer.int16ChannelData?.pointee else { return }
            channel.update(from: source, count: samples)
        }
        let compressedBuffer = AVAudioCompressedBuffer(format: outputFormat,
                                                       packetCapacity: 1,
                                                       maximumPacketSize: maxPacketSize)
        var error: NSError?
        var didProvide = false
        encoder.convert(to: compressedBuffer, error: &error) { _, outStatus in
            if didProvide {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvide = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }
        guard error == nil, compressedBuffer.byteLength > 0 else { return nil }
        return Data(bytes: compressedBuffer.data, count: Int(compressedBuffer.byteLength))
    }

    func decode(_ opusData: Data) -> Data? {
        guard !opusData.isEmpty else { return nil }
        let compressedBuffer = AVAudioCompressedBuffer(format: outputFormat,
                                                       packetCapacity: 1,
                                                       maximumPacketSize: opusData.count)
        compressedBuffer.packetCount = 1
        compressedBuffer.byteLength = UInt32(opusData.count)
        opusData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            compressedBuffer.data.copyMemory(from: base, byteCount: opusData.count)
        }
        if let desc = compressedBuffer.packetDescriptions {
            desc.pointee.mDataByteSize = UInt32(opusData.count)
            desc.pointee.mStartOffset = 0
            desc.pointee.mVariableFramesInPacket = 0
        }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                               frameCapacity: frameCapacity) else { return nil }
        var error: NSError?
        var didProvide = false
        decoder.convert(to: pcmBuffer, error: &error) { _, outStatus in
            if didProvide {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvide = true
            outStatus.pointee = .haveData
            return compressedBuffer
        }
        guard error == nil, pcmBuffer.frameLength > 0 else { return nil }
        let samples = Int(pcmBuffer.frameLength)
        guard let channel = pcmBuffer.int16ChannelData?.pointee else { return nil }
        return Data(bytes: channel, count: samples * MemoryLayout<Int16>.size)
    }
}
