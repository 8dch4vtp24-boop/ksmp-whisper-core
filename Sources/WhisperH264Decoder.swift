import Foundation
import VideoToolbox
import CoreImage
import UIKit

final class WhisperH264Decoder {
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private let context = CIContext()
    private var lastImage: UIImage?
    private let decodeQueue = DispatchQueue(label: "whisper.video.decode")

    func decode(_ data: Data) -> UIImage? {
        guard !data.isEmpty else { return nil }
        return decodeQueue.sync {
            let nalUnits = splitNALUnits(data)
            guard !nalUnits.isEmpty else { return nil }
            var sps: Data?
            var pps: Data?
            var frames: [Data] = []
            for nal in nalUnits {
                guard let first = nal.first else { continue }
                let type = first & 0x1F
                switch type {
                case 7:
                    sps = nal
                case 8:
                    pps = nal
                default:
                    frames.append(nal)
                }
            }
            if let sps, let pps {
                if formatDescription == nil || !formatMatches(sps: sps, pps: pps) {
                    setupFormat(sps: sps, pps: pps)
                }
            }
            guard let formatDescription else { return nil }
            guard let sampleBuffer = makeSampleBuffer(nals: frames, formatDescription: formatDescription) else { return nil }
            return decodeSampleBuffer(sampleBuffer)
        }
    }

    private func formatMatches(sps: Data, pps: Data) -> Bool {
        guard let formatDescription else { return false }
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var spsCount = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        var ppsCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription,
                                                           parameterSetIndex: 0,
                                                           parameterSetPointerOut: &spsPointer,
                                                           parameterSetSizeOut: &spsSize,
                                                           parameterSetCountOut: &spsCount,
                                                           nalUnitHeaderLengthOut: nil)
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription,
                                                           parameterSetIndex: 1,
                                                           parameterSetPointerOut: &ppsPointer,
                                                           parameterSetSizeOut: &ppsSize,
                                                           parameterSetCountOut: &ppsCount,
                                                           nalUnitHeaderLengthOut: nil)
        guard let spsPointer, let ppsPointer else { return false }
        let currentSps = Data(bytes: spsPointer, count: spsSize)
        let currentPps = Data(bytes: ppsPointer, count: ppsSize)
        return currentSps == sps && currentPps == pps
    }

    private func setupFormat(sps: Data, pps: Data) {
        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                let parameterSetPointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let parameterSetSizes: [Int] = [sps.count, pps.count]
                var format: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                                                                    parameterSetCount: 2,
                                                                    parameterSetPointers: parameterSetPointers,
                                                                    parameterSetSizes: parameterSetSizes,
                                                                    nalUnitHeaderLength: 4,
                                                                    formatDescriptionOut: &format)
                formatDescription = format
                if let session = session {
                    VTDecompressionSessionInvalidate(session)
                }
                session = nil
                if let format {
                    createSession(format: format)
                }
            }
        }
    }

    private func createSession(format: CMVideoFormatDescription) {
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            let decoder = Unmanaged<WhisperH264Decoder>.fromOpaque(refCon!).takeUnretainedValue()
            decoder.handleDecodedImage(imageBuffer)
        }, decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        let attrs: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        var newSession: VTDecompressionSession?
        VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                     formatDescription: format,
                                     decoderSpecification: nil,
                                     imageBufferAttributes: attrs as CFDictionary,
                                     outputCallback: &callback,
                                     decompressionSessionOut: &newSession)
        if let newSession {
            VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            session = newSession
        }
    }

    private func handleDecodedImage(_ imageBuffer: CVImageBuffer) {
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            lastImage = UIImage(cgImage: cgImage)
        }
    }

    private func makeSampleBuffer(nals: [Data], formatDescription: CMVideoFormatDescription) -> CMSampleBuffer? {
        guard !nals.isEmpty else { return nil }
        var avcc = Data()
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(nal)
        }
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: nil,
                                                        blockLength: avcc.count,
                                                        blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil,
                                                        offsetToData: 0,
                                                        dataLength: avcc.count,
                                                        flags: 0,
                                                        blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                  dataBuffer: blockBuffer,
                                  formatDescription: formatDescription,
                                  sampleCount: 1,
                                  sampleTimingEntryCount: 1,
                                  sampleTimingArray: &timing,
                                  sampleSizeEntryCount: 1,
                                  sampleSizeArray: &sampleSize,
                                  sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }

    private func decodeSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> UIImage? {
        guard let session else { return nil }
        lastImage = nil
        let flags = VTDecodeFrameFlags()
        var infoFlags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: flags, frameRefcon: nil, infoFlagsOut: &infoFlags)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return lastImage
    }

    private func splitNALUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        var starts: [(index: Int, length: Int)] = []
        var i = 0
        while i + 3 < bytes.count {
            let isStartCode3 = bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1
            let isStartCode4 = i + 4 < bytes.count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1
            if isStartCode3 || isStartCode4 {
                starts.append((i, isStartCode3 ? 3 : 4))
                i += isStartCode3 ? 3 : 4
            } else {
                i += 1
            }
        }
        for (idx, entry) in starts.enumerated() {
            let start = entry.index + entry.length
            let end = (idx + 1 < starts.count) ? starts[idx + 1].index : bytes.count
            guard end > start else { continue }
            units.append(Data(bytes[start..<end]))
        }
        return units
    }
}
