#if DEBUG
import AVFoundation

/// Explicitly constructed by recorder tests. No launch argument, environment,
/// simulator check or production factory ever selects this source.
struct TimestampedSampleSource {
    let origin: Double
    let frameDuration: CMTime
    let audioOffset: Double
    let gaps: [Int: Double]
    static let width = 128
    static let height = 96
    static let sampleRate = 44_100

    init(origin: Double = 1_000, frameDuration: CMTime = CMTime(value: 1, timescale: 10),
         audioOffset: Double = 0, gaps: [Int: Double] = [:]) {
        self.origin = origin
        self.frameDuration = frameDuration
        self.audioOffset = audioOffset
        self.gaps = gaps
    }
    func timestamp(frame: Int) -> Double {
        origin + Double(frame) * frameDuration.seconds + gaps.filter { $0.key <= frame }.values.reduce(0, +)
    }
    /// Sixteen large black/white bars encode the source frame number. A decoded
    /// frame therefore identifies original media time even after trimming/export.
    func video(frame: Int) throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, Self.width, Self.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess,
              let image else { throw CameraError.unavailable }
        CVPixelBufferLockBaseAddress(image, [])
        let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<Self.height { for x in 0..<Self.width {
            let level: UInt8 = frame & (1 << (x / 8)) == 0 ? 16 : 235
            let offset = y * stride + x * 4
            bytes[offset] = level; bytes[offset + 1] = level
            bytes[offset + 2] = level; bytes[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(image, [])
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
            formatDescriptionOut: &description) == noErr, let description else { throw CameraError.unavailable }
        var timing = CMSampleTimingInfo(duration: frameDuration,
            presentationTimeStamp: CMTime(seconds: timestamp(frame: frame), preferredTimescale: 44_100),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { throw CameraError.unavailable }
        return sample
    }
    /// PCM uses a known frequency selected by source second, making silence,
    /// missing chunks, and misplaced audio distinguishable after AAC decoding.
    func audio(frame: Int) throws -> CMSampleBuffer {
        let count = Int((frameDuration.seconds * Double(Self.sampleRate)).rounded())
        let logicalTime = timestamp(frame: frame) - origin
        let frequency = Self.frequency(at: logicalTime)
        var format = AudioStreamBasicDescription(mSampleRate: Double(Self.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr,
              let description else { throw CameraError.unavailable }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: count * 2,
            flags: 0, blockBufferOut: &block) == noErr, let block else { throw CameraError.unavailable }
        let samples: [Int16] = (0..<count).map {
            Int16(sin((logicalTime + Double($0) / Double(Self.sampleRate)) * frequency * 2 * .pi) * 12_000)
        }
        let status = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: count * 2)
        }
        guard status == kCMBlockBufferNoErr else { throw CameraError.unavailable }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block,
            formatDescription: description, sampleCount: count,
            presentationTimeStamp: CMTime(seconds: timestamp(frame: frame) + audioOffset, preferredTimescale: 44_100),
            packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample else { throw CameraError.unavailable }
        return sample
    }
    static func frequency(at logicalTime: Double) -> Double { 440 + Double(Int(floor(logicalTime + 0.00001)) % 4) * 110 }
}
#endif
