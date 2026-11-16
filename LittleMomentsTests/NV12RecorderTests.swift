import AVFoundation
import XCTest
@testable import LittleMoments

/// Portrait bi-planar samples carry BT.709 metadata, source frame identity, and
/// saturated color bars. These enter the production RollingRecorder unchanged.
private struct NV12ColorBars {
    static let width = 96, height = 128
    static let colors: [(Double, Double, Double)] = [
        (1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0),
        (1, 0, 1), (1, 0, 0), (0, 0, 1), (0, 0, 0)
    ]
    let pixelFormat: OSType
    let clock = TimestampedSampleSource(frameDuration: CMTime(value: 1, timescale: 30))
    func sample(_ frame: Int) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, Self.width, Self.height, pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw CameraError.unavailable }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let full = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        func components(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let rgb: (Double, Double, Double)
            if y < 16 {
                let level: Double = frame & (1 << (x / 12)) == 0 ? 0 : 1
                rgb = (level, level, level)
            } else { rgb = Self.colors[x / 12] }
            let y = 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
            func byte(_ value: Double) -> UInt8 { UInt8(max(0, min(255, value.rounded()))) }
            return (byte(y * (full ? 255 : 219) + (full ? 0 : 16)),
                    byte((rgb.2 - y) / 1.8556 * (full ? 255 : 224) + 128),
                    byte((rgb.0 - y) / 1.5748 * (full ? 255 : 224) + 128))
        }
        for y in 0..<Self.height { for x in 0..<Self.width { luma[y * lumaStride + x] = components(x: x, y: y).0 } }
        for y in 0..<(Self.height / 2) { for x in 0..<(Self.width / 2) {
            let value = components(x: x * 2, y: y * 2)
            chroma[y * chromaStride + x * 2] = value.1
            chroma[y * chromaStride + x * 2 + 1] = value.2
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescriptionOut: &description) == noErr, let description else { throw CameraError.unavailable }
        var timing = CMSampleTimingInfo(duration: clock.frameDuration,
            presentationTimeStamp: CMTime(seconds: clock.timestamp(frame: frame), preferredTimescale: 44_100),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { throw CameraError.unavailable }
        return sample
    }
}

final class NV12RecorderTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("NV12-" + UUID().uuidString)
        try ProtectedFiles.directory(directory)
    }
    override func tearDownWithError() throws {
        if let run = testRun, run.failureCount > 0 {
            let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if ["mov", "mp4"].contains(url.pathExtension) {
                    let attachment = XCTAttachment(contentsOfFile: url); attachment.lifetime = .keepAlways; add(attachment)
                }
            }
        }
        try FileManager.default.removeItem(at: directory)
    }
    func testFullRangeNV12WithAudio() async throws { try await roundTrip(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, audio: true) }
    func testFullRangeNV12WithoutAudio() async throws { try await roundTrip(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, audio: false) }
    func testVideoRangeNV12WithAudio() async throws { try await roundTrip(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, audio: true) }
    func testVideoRangeNV12WithoutAudio() async throws { try await roundTrip(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, audio: false) }

    private func roundTrip(_ pixelFormat: OSType, audio: Bool) async throws {
        let source = NV12ColorBars(pixelFormat: pixelFormat)
        let first = try source.sample(0)
        let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(first))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), pixelFormat)
        XCTAssertEqual(CVPixelBufferGetPlaneCount(image), 2)
        let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(first))
        XCTAssertEqual(CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String,
                       kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        let recorder = RollingRecorder(queue: DispatchQueue(label: "NV12Test"), directory: directory.appendingPathComponent("buffer"))
        await perform(recorder) { recorder.start(audio: audio, duration: 15) }
        var previous = 0
        for endpoint in [31, 61, 97] {
            for frame in previous..<endpoint {
                try await recorder.appendManually(source.sample(frame), isAudio: false)
                if audio { try await recorder.appendManually(source.clock.audio(frame: frame), isAudio: true) }
            }
            let snapshot = try await recorder.snapshot()
            let output = directory.appendingPathComponent("\(endpoint).mp4")
            try await ClipComposer().compose(snapshot, to: output)
            try verify(output, frames: endpoint, audio: audio)
            await recorder.release(snapshot)
            previous = endpoint
        }
        await perform(recorder) { recorder.stop() }
        let diagnostics = try await recorder.diagnostics()
        XCTAssertTrue(diagnostics.files.isEmpty)
    }
    private func perform(_ recorder: RollingRecorder, _ body: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in recorder.queue.async { body(); continuation.resume() } }
    }
    private func verify(_ url: URL, frames expectedFrames: Int, audio: Bool) throws {
        let asset = AVURLAsset(url: url)
        let video = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        XCTAssertEqual(video.naturalSize, CGSize(width: CGFloat(NV12ColorBars.width), height: CGFloat(NV12ColorBars.height)))
        let transformed = CGRect(origin: .zero, size: video.naturalSize).applying(video.preferredTransform)
        XCTAssertLessThan(abs(transformed.width), abs(transformed.height))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            XCTAssertEqual(CVPixelBufferGetWidth(image), NV12ColorBars.width)
            XCTAssertEqual(CVPixelBufferGetHeight(image), NV12ColorBars.height)
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(image)
            var marker = 0
            for bit in 0..<8 where bytes[8 * stride + (bit * 12 + 6) * 4 + 1] > 128 { marker |= 1 << bit }
            XCTAssertEqual(marker, count)
            if count == 0 || count == expectedFrames - 1 {
                for (bar, color) in NV12ColorBars.colors.enumerated() {
                    let index = 64 * stride + (bar * 12 + 6) * 4
                    XCTAssertEqual(Double(bytes[index + 2]), color.0 * 255, accuracy: 30, "red bar \(bar)")
                    XCTAssertEqual(Double(bytes[index + 1]), color.1 * 255, accuracy: 30, "green bar \(bar)")
                    XCTAssertEqual(Double(bytes[index]), color.2 * 255, accuracy: 30, "blue bar \(bar)")
                }
            }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, Double(count) / 30, accuracy: 0.002)
            count += 1
        }
        XCTAssertEqual(reader.status, .completed); XCTAssertEqual(count, expectedFrames)
        let videoRange = video.timeRange
        XCTAssertEqual(videoRange.duration.seconds, Double(expectedFrames) / 30, accuracy: 0.04)
        let audioTracks = asset.tracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, audio ? 1 : 0)
        if let track = audioTracks.first {
            XCTAssertEqual(track.timeRange.start.seconds, videoRange.start.seconds, accuracy: 0.03)
            XCTAssertEqual(track.timeRange.duration.seconds, videoRange.duration.seconds, accuracy: 0.06)
            try verifyAudio(asset, track: track)
        }
    }
    private func verifyAudio(_ asset: AVAsset, track: AVAssetTrack) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var count = 0, nonSilent = 0
        while let sample = output.copyNextSampleBuffer() {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var values = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
            XCTAssertEqual(values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }, kCMBlockBufferNoErr)
            if values.contains(where: { abs(Int($0)) > 3000 }) { nonSilent += 1 }
            count += 1
        }
        XCTAssertEqual(reader.status, .completed); XCTAssertGreaterThan(count, 0); XCTAssertGreaterThan(nonSilent, 0)
    }
}
