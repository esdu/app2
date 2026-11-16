import AVFoundation

/// Value-only selection keeps unsupported combinations testable without a camera.
struct CaptureFormatPolicy {
    struct RateRange { let minimum: Double; let maximum: Double }
    struct Candidate {
        let index: Int
        let width: Int32
        let height: Int32
        let rates: [RateRange]
    }
    static let frameDuration = CMTime(value: 1, timescale: 30)
    static func select(_ candidates: [Candidate]) throws -> Candidate {
        let supported = candidates.filter { candidate in
            candidate.width > 0 && candidate.height > 0 && candidate.width <= 1280 && candidate.height <= 720 &&
            candidate.rates.contains { $0.minimum.isFinite && $0.maximum.isFinite && $0.minimum <= 30 && $0.maximum >= 30 }
        }
        guard let selected = supported.sorted(by: {
            let left = Int64($0.width) * Int64($0.height), right = Int64($1.width) * Int64($1.height)
            return left == right ? $0.index < $1.index : left > right
        }).first else {
            throw CameraError.writer("This camera has no supported 30 fps format at 720p or below. Switch cameras and tap Start Buffer to retry.")
        }
        return selected
    }
    static func pixelFormat(supported: [OSType]) throws -> OSType {
        for preferred in [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA] {
            if supported.contains(preferred) { return preferred }
        }
        throw CameraError.writer("This camera cannot deliver supported NV12 or BGRA video. Switch cameras and tap Start Buffer to retry.")
    }
    static func name(_ pixelFormat: OSType) -> String {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "NV12 full range"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "NV12 video range"
        case kCVPixelFormatType_32BGRA: return "BGRA fallback"
        default: return "unsupported \(pixelFormat)"
        }
    }
}

/// Checks what the delegate actually receives, rather than trusting a preset.
struct CaptureDeliveryValidator {
    let width: Int32
    let height: Int32
    let pixelFormat: OSType
    private(set) var frames = 0
    private(set) var firstPTS: Double?
    private(set) var lastPTS: Double?
    var observedFPS: Double? {
        guard frames > 1, let firstPTS, let lastPTS, lastPTS > firstPTS else { return nil }
        return Double(frames - 1) / (lastPTS - firstPTS)
    }
    mutating func validate(width: Int32, height: Int32, pixelFormat: OSType, pts: Double) throws {
        guard width == self.width, height == self.height, pixelFormat == self.pixelFormat else {
            throw CameraError.writer("Camera delivered an unexpected video format (\(width)×\(height), \(CaptureFormatPolicy.name(pixelFormat))). Buffering stopped. Switch cameras and retry.")
        }
        guard pts.isFinite else { throw CameraError.writer("Camera delivered an invalid video timestamp. Tap Start Buffer to retry.") }
        if let lastPTS {
            guard pts > lastPTS, pts - lastPTS >= 1.0 / 30 - 0.003 else {
                throw CameraError.writer("Camera did not honor the configured 30 fps timing. Buffering stopped. Switch cameras and retry.")
            }
        } else { firstPTS = pts }
        frames += 1
        lastPTS = pts
    }
    mutating func validate(_ sample: CMSampleBuffer) throws {
        guard let image = CMSampleBufferGetImageBuffer(sample),
              let description = CMSampleBufferGetFormatDescription(sample) else { throw CameraError.unavailable }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        try validate(width: dimensions.width, height: dimensions.height,
                     pixelFormat: CVPixelBufferGetPixelFormatType(image),
                     pts: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        guard CVPixelBufferGetWidth(image) == Int(width), CVPixelBufferGetHeight(image) == Int(height) else {
            throw CameraError.writer("Camera image dimensions changed. Tap Start Buffer to retry.")
        }
    }
}
