import XCTest
@testable import OpenGlasses

/// Pure-decision coverage for the recording guards: the storage verdict (refuse / warn-with-
/// estimate / ok) and the stream-death watchdog (auto-stop only after frames have flowed and
/// then stalled). The I/O edges (disk query, AVAssetWriter, timers) stay untested by design.
@MainActor
final class VideoRecordingGuardTests: XCTestCase {

    // MARK: - Storage verdict

    func testInsufficientBelowHardFloor() {
        XCTAssertEqual(
            VideoRecordingService.storageVerdict(freeBytes: 150_000_000, videoBitrate: 1_500_000),
            .insufficient)
    }

    func testLowStorageCarriesMinutesEstimate() {
        // 1 GB free at 1.5 Mbps video + 64 kbps audio ≈ 195.5 KB/s → ~85 minutes.
        let verdict = VideoRecordingService.storageVerdict(freeBytes: 1_000_000_000, videoBitrate: 1_500_000)
        guard case .low(let minutes) = verdict else {
            return XCTFail("1 GB free should be low, got \(verdict)")
        }
        XCTAssertEqual(minutes, 85)
    }

    func testPlentyOfStorageIsOK() {
        XCTAssertEqual(
            VideoRecordingService.storageVerdict(freeBytes: 50_000_000_000, videoBitrate: 1_500_000),
            .ok)
    }

    func testHigherBitrateShrinksTheEstimate() {
        guard case .low(let slow) = VideoRecordingService.storageVerdict(freeBytes: 1_000_000_000, videoBitrate: 1_500_000),
              case .low(let fast) = VideoRecordingService.storageVerdict(freeBytes: 1_000_000_000, videoBitrate: 6_000_000) else {
            return XCTFail("both should be low")
        }
        XCTAssertGreaterThan(slow, fast, "a higher bitrate must estimate fewer minutes")
    }

    // MARK: - Stream-death watchdog

    func testNoAutoStopBeforeFirstFrame() {
        // Waiting for the stream to warm up is not a stall — never stop a frameless recording.
        XCTAssertFalse(VideoRecordingService.shouldAutoStop(
            isRecording: true, lastFrameAt: nil, now: Date()))
    }

    func testNoAutoStopWhileFramesFlow() {
        let now = Date()
        XCTAssertFalse(VideoRecordingService.shouldAutoStop(
            isRecording: true, lastFrameAt: now.addingTimeInterval(-2), now: now))
    }

    func testAutoStopAfterStall() {
        let now = Date()
        XCTAssertTrue(VideoRecordingService.shouldAutoStop(
            isRecording: true,
            lastFrameAt: now.addingTimeInterval(-VideoRecordingService.frameStallSeconds - 1),
            now: now))
    }

    func testNoAutoStopWhenNotRecording() {
        let now = Date()
        XCTAssertFalse(VideoRecordingService.shouldAutoStop(
            isRecording: false, lastFrameAt: now.addingTimeInterval(-600), now: now))
    }
}
