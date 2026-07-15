import XCTest
import UIKit
@testable import OpenGlasses

/// Plan BS — transcript guard, broadcast geometry/clock/selector/compositor.
final class BSHardeningTests: XCTestCase {

    // MARK: P1 — TranscriptGuard energy gate

    func testEnergyGateRejectsSilenceAndPassesSpeechLevels() {
        let silence = [Float](repeating: 0.0, count: 16000)
        XCTAssertFalse(TranscriptGuard.passesEnergyGate(samples: silence))

        let nearSilence = (0..<16000).map { _ in Float.random(in: -0.0005...0.0005) }
        XCTAssertFalse(TranscriptGuard.passesEnergyGate(samples: nearSilence))

        // Quiet speech ≈ sine at 2% full scale — must pass.
        let quietSpeech = (0..<16000).map { Float(sin(Double($0) * 0.05)) * 0.02 }
        XCTAssertTrue(TranscriptGuard.passesEnergyGate(samples: quietSpeech))

        XCTAssertFalse(TranscriptGuard.passesEnergyGate(samples: []))
    }

    // MARK: P1 — artifact filter

    func testFilterDropsKnownBoilerplate() {
        XCTAssertNil(TranscriptGuard.filter("MBC 뉴스 이덕영입니다", expectedLocaleIdentifier: "en-US"))
        XCTAssertNil(TranscriptGuard.filter("ご視聴ありがとうございました", expectedLocaleIdentifier: "en-US"))
        XCTAssertNil(TranscriptGuard.filter("Thanks for watching!", expectedLocaleIdentifier: "en-US"))
        XCTAssertNil(TranscriptGuard.filter("Subtitles by the Amara.org community", expectedLocaleIdentifier: "en-US"))
    }

    func testFilterDropsDegenerateRepetition() {
        XCTAssertNil(TranscriptGuard.filter("okay okay okay okay okay", expectedLocaleIdentifier: "en-US"))
        // Three repeats is below the threshold — kept (conservative).
        XCTAssertNotNil(TranscriptGuard.filter("okay okay okay", expectedLocaleIdentifier: "en-US"))
    }

    func testFilterScriptMismatchOnlyAgainstExplicitNonCJKLocale() {
        let korean = "안녕하세요 오늘 날씨가 좋네요"
        XCTAssertNil(TranscriptGuard.filter(korean, expectedLocaleIdentifier: "en-US"),
                     "majority-CJK against explicit en locale is an artifact")
        XCTAssertNotNil(TranscriptGuard.filter(korean, expectedLocaleIdentifier: "ko-KR"),
                        "Korean against a Korean locale is speech")
        XCTAssertNotNil(TranscriptGuard.filter(korean, expectedLocaleIdentifier: "auto"),
                        "auto locale must not apply the script rule")
        XCTAssertNotNil(TranscriptGuard.filter(korean, expectedLocaleIdentifier: nil))
    }

    func testFilterKeepsOrdinarySpeech() {
        XCTAssertEqual(
            TranscriptGuard.filter("  Remind me to call the dentist tomorrow. ", expectedLocaleIdentifier: "en-US"),
            "Remind me to call the dentist tomorrow.")
        // Mixed text with a minority CJK word survives the script rule.
        XCTAssertNotNil(TranscriptGuard.filter("The sign said 出口 which means exit", expectedLocaleIdentifier: "en-US"))
    }

    // MARK: P2 — geometry

    func testOutputSizeByOrientation() {
        XCTAssertEqual(BroadcastGeometry.outputSize(orientation: "portrait").width, 720)
        XCTAssertEqual(BroadcastGeometry.outputSize(orientation: "portrait").height, 1280)
        XCTAssertEqual(BroadcastGeometry.outputSize(orientation: "landscape").width, 1280)
        XCTAssertEqual(BroadcastGeometry.outputSize(orientation: "landscape").height, 720)
        XCTAssertEqual(BroadcastGeometry.outputSize(orientation: "garbage").width, 720, "unknown → portrait")
    }

    func testAspectFitLetterboxes() {
        // Landscape 16:9 image into portrait 720×1280 canvas → full width, centered.
        let rect = BroadcastGeometry.aspectFitRect(
            imageSize: CGSize(width: 1920, height: 1080),
            in: CGSize(width: 720, height: 1280))
        XCTAssertEqual(rect.width, 720, accuracy: 0.5)
        XCTAssertEqual(rect.height, 405, accuracy: 0.5)
        XCTAssertEqual(rect.midY, 640, accuracy: 0.5)

        // Matching aspect fills exactly.
        let full = BroadcastGeometry.aspectFitRect(
            imageSize: CGSize(width: 720, height: 1280),
            in: CGSize(width: 720, height: 1280))
        XCTAssertEqual(full, CGRect(x: 0, y: 0, width: 720, height: 1280))

        XCTAssertEqual(BroadcastGeometry.aspectFitRect(imageSize: .zero, in: CGSize(width: 10, height: 10)), .zero)
    }

    // MARK: P2 — audio clock

    func testAudioClockMonotonicAdvance() {
        var clock = BroadcastAudioClock()
        XCTAssertEqual(clock.take(frames: 1024), 0)
        XCTAssertEqual(clock.take(frames: 1024), 1024)
        XCTAssertEqual(clock.take(frames: 512), 2048)
        XCTAssertEqual(clock.sampleTime, 2560)
    }

    // MARK: P3 — source selector

    func testSelectorDebouncesRapidSwitches() {
        var selector = BroadcastSourceSelector(initial: .glasses, debounce: 1.0)
        let t0 = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(selector.requestSwitch(to: .phoneBack, now: t0))
        XCTAssertEqual(selector.active, .phoneBack)
        // Within debounce → rejected.
        XCTAssertFalse(selector.requestSwitch(to: .glasses, now: t0.addingTimeInterval(0.4)))
        XCTAssertEqual(selector.active, .phoneBack)
        // After debounce → accepted.
        XCTAssertTrue(selector.requestSwitch(to: .glasses, now: t0.addingTimeInterval(1.1)))
        XCTAssertEqual(selector.active, .glasses)
        // No-op switch to the current source.
        XCTAssertFalse(selector.requestSwitch(to: .glasses, now: t0.addingTimeInterval(5)))
    }

    // MARK: P3 — compositor

    private func solidImage(size: CGSize, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testInsetRectBottomTrailing() {
        let rect = FrameCompositor.insetRect(
            canvas: CGSize(width: 720, height: 1280),
            insetAspect: 16.0 / 9.0)
        XCTAssertEqual(rect.width, 216, accuracy: 0.5)          // 30% of 720
        XCTAssertEqual(rect.height, 121.5, accuracy: 0.5)
        XCTAssertEqual(rect.maxX, 720 - 16, accuracy: 0.5)      // trailing margin
        XCTAssertEqual(rect.maxY, 1280 - 16, accuracy: 0.5)     // bottom margin
    }

    func testComposeWithoutInsetReturnsMainUntouched() {
        let main = solidImage(size: CGSize(width: 72, height: 128), color: .black)
        XCTAssertTrue(FrameCompositor.compose(main: main, inset: nil) === main)
    }

    func testComposePreservesCanvasSizeAndDrawsInset() {
        let main = solidImage(size: CGSize(width: 720, height: 1280), color: .black)
        let inset = solidImage(size: CGSize(width: 160, height: 90), color: .white)
        let composed = FrameCompositor.compose(main: main, inset: inset)
        XCTAssertEqual(composed.size, main.size)

        // Sample the inset region centre — must not be black anymore.
        let rect = FrameCompositor.insetRect(canvas: main.size, insetAspect: 160.0 / 90.0)
        guard let cgImage = composed.cgImage,
              let data = cgImage.dataProvider?.data as Data? else {
            return XCTFail("no bitmap")
        }
        let x = Int(rect.midX), y = Int(rect.midY)
        let bytesPerRow = cgImage.bytesPerRow
        let offset = y * bytesPerRow + x * (cgImage.bitsPerPixel / 8)
        XCTAssertGreaterThan(data[offset], 200, "inset centre should be white")
    }
}
