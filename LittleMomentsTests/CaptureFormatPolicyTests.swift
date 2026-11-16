import AVFoundation
import XCTest
@testable import LittleMoments

final class CaptureFormatPolicyTests: XCTestCase {
    private func candidate(_ index: Int, _ width: Int32 = 1280, _ height: Int32 = 720,
                           _ minimum: Double = 15, _ maximum: Double = 60) -> CaptureFormatPolicy.Candidate {
        .init(index: index, width: width, height: height, rates: [.init(minimum: minimum, maximum: maximum)])
    }
    func testSelects720p30AndChecksBothRangeBounds() throws {
        let result = try CaptureFormatPolicy.select([candidate(0, 1280, 720, 60, 120),
            candidate(1, 1280, 720, 1, 29.97), candidate(2), candidate(3, 1920, 1080)])
        XCTAssertEqual(result.index, 2)
        XCTAssertThrowsError(try CaptureFormatPolicy.select([candidate(0, 1280, 720, 31, 60)]))
        XCTAssertThrowsError(try CaptureFormatPolicy.select([candidate(0, 1280, 720, 1, 29.97)]))
    }
    func testExplicitSmallerFallbackNeverSelectsHigherResolutionOrUnsupportedFPS() throws {
        let result = try CaptureFormatPolicy.select([candidate(0, 1920, 1080), candidate(1, 640, 480),
            candidate(2, 1280, 720, 60, 120), candidate(3, 352, 288)])
        XCTAssertEqual(result.index, 1)
        XCTAssertThrowsError(try CaptureFormatPolicy.select([candidate(0, 1920, 1080)]))
        XCTAssertThrowsError(try CaptureFormatPolicy.select([]))
        XCTAssertThrowsError(try CaptureFormatPolicy.select([candidate(0, 0, 0)]))
    }
    func testAnyAdvertisedRangeCanProvide30AndSelectionIsDeterministic() throws {
        let multi = CaptureFormatPolicy.Candidate(index: 4, width: 1280, height: 720,
            rates: [.init(minimum: 60, maximum: 120), .init(minimum: 30, maximum: 30)])
        XCTAssertEqual(try CaptureFormatPolicy.select([multi]).index, 4)
        XCTAssertEqual(try CaptureFormatPolicy.select([candidate(3), candidate(2)]).index, 2)
        XCTAssertThrowsError(try CaptureFormatPolicy.select([candidate(0, 1280, 720, .nan, 60)]))
    }
    func testNV12RangePreferenceAndDeliberateBGRAFallback() throws {
        let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let limited = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        XCTAssertEqual(try CaptureFormatPolicy.pixelFormat(supported: [kCVPixelFormatType_32BGRA, limited, full]), full)
        XCTAssertEqual(try CaptureFormatPolicy.pixelFormat(supported: [limited]), limited)
        XCTAssertEqual(try CaptureFormatPolicy.pixelFormat(supported: [kCVPixelFormatType_32BGRA]), kCVPixelFormatType_32BGRA)
        XCTAssertThrowsError(try CaptureFormatPolicy.pixelFormat(supported: []))
    }
    func testDeliveredPortraitDimensionsFormatAndCadenceAreValidated() throws {
        var validator = CaptureDeliveryValidator(width: 720, height: 1280, pixelFormat: kCVPixelFormatType_32BGRA)
        for index in 0..<60 {
            try validator.validate(width: 720, height: 1280, pixelFormat: kCVPixelFormatType_32BGRA,
                                   pts: 1000 + Double(index) / 30)
        }
        XCTAssertEqual(try XCTUnwrap(validator.observedFPS), 30, accuracy: 0.001)
        XCTAssertThrowsError(try validator.validate(width: 1280, height: 720, pixelFormat: kCVPixelFormatType_32BGRA, pts: 1002))
        XCTAssertThrowsError(try validator.validate(width: 720, height: 1280,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, pts: 1002))
        XCTAssertThrowsError(try validator.validate(width: 720, height: 1280, pixelFormat: kCVPixelFormatType_32BGRA, pts: .nan))
        XCTAssertThrowsError(try validator.validate(width: 720, height: 1280, pixelFormat: kCVPixelFormatType_32BGRA,
            pts: 1000 + 59.5 / 30))
        try validator.validate(width: 720, height: 1280, pixelFormat: kCVPixelFormatType_32BGRA, pts: 1003)
        XCTAssertLessThan(try XCTUnwrap(validator.observedFPS), 30) // dropped frames are diagnosed, not a false fps claim
    }
    func testFreshStartHasNoStaleCameraFormatOrCadence() throws {
        let source = try TimestampedSampleSource(frameDuration: CMTime(value: 1, timescale: 30)).video(frame: 0)
        var old = CaptureDeliveryValidator(width: 128, height: 96, pixelFormat: kCVPixelFormatType_32BGRA)
        try old.validate(source)
        var next = CaptureDeliveryValidator(width: 96, height: 128, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        XCTAssertNil(next.observedFPS); XCTAssertEqual(next.frames, 0)
        XCTAssertThrowsError(try next.validate(source))
    }
}
