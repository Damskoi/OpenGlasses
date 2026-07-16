import XCTest
import UIKit
@testable import OpenGlasses

/// Tests `PageTurnDetector` (docs/plans/BT-reading-companion.md P1): the settle state machine at
/// hash level, plus the fixture-image sequence the plan calls for — page A → mid-turn blur → hand
/// occlusion → page B, where only the two real pages may reach OCR. Headless.
final class PageTurnDetectorTests: XCTestCase {

    private func detector(stabilityWindow: TimeInterval = 1.0,
                          heartbeat: TimeInterval = 0) -> PageTurnDetector {
        PageTurnDetector(gate: FrameGate(hammingThreshold: 3, heartbeat: heartbeat, adaptiveEnabled: false),
                         stabilityWindow: stabilityWindow)
    }

    // MARK: - State machine

    func testStillPageSettlesOnceAfterTheWindow() {
        var d = detector()
        let page: UInt64 = 0xFFFF_0000_FFFF_0000
        XCTAssertEqual(d.evaluate(hash: page, now: 0), .none)        // change: candidate opens
        XCTAssertEqual(d.evaluate(hash: page, now: 0.5), .none)      // still settling
        XCTAssertEqual(d.evaluate(hash: page, now: 1.0), .pageSettled(hash: page))
        // Already reported — lingering on the same page must not re-fire.
        XCTAssertEqual(d.evaluate(hash: page, now: 2.0), .none)
        XCTAssertEqual(d.evaluate(hash: page, now: 30.0), .none)
        XCTAssertEqual(d.settledCount, 1)
    }

    func testSettledHashIsTheConfirmingFrameNotTheCandidate() {
        var d = detector()
        let candidate: UInt64 = 0x0000_0000_0000_0000
        let confirming: UInt64 = 0x0000_0000_0000_0003   // within threshold 3 → a drop
        XCTAssertEqual(d.evaluate(hash: candidate, now: 0), .none)
        // The frame we OCR is the one in hand, so its own hash is what comes back for store dedup.
        XCTAssertEqual(d.evaluate(hash: confirming, now: 1.0), .pageSettled(hash: confirming))
    }

    func testTransientFramesNeverSettle() {
        var d = detector()
        // Every frame is wildly different from the last — a hand sweeping across, blur mid-turn.
        // Nothing ever holds still, so nothing is ever handed to OCR.
        let transients: [UInt64] = [0x0000_0000_0000_0000, 0xFFFF_FFFF_FFFF_FFFF,
                                    0x0F0F_0F0F_0F0F_0F0F, 0xF0F0_F0F0_F0F0_F0F0,
                                    0x00FF_00FF_00FF_00FF]
        for (i, hash) in transients.enumerated() {
            XCTAssertEqual(d.evaluate(hash: hash, now: TimeInterval(i) * 0.2), .none)
        }
        XCTAssertEqual(d.settledCount, 0)
        XCTAssertEqual(d.rejectedCandidateCount, 4)   // each candidate abandoned by the next change
    }

    func testStillnessShorterThanTheWindowDoesNotSettle() {
        var d = detector(stabilityWindow: 2.0)
        let page: UInt64 = 0xABCD
        XCTAssertEqual(d.evaluate(hash: page, now: 0), .none)
        XCTAssertEqual(d.evaluate(hash: page, now: 1.9), .none)
        XCTAssertTrue(d.isSettling)
        XCTAssertEqual(d.evaluate(hash: page, now: 2.0), .pageSettled(hash: page))
        XCTAssertFalse(d.isSettling)
    }

    func testChangeRestartsTheStabilityClock() {
        var d = detector()
        let pageA: UInt64 = 0x0000_0000_0000_0000
        let pageB: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
        XCTAssertEqual(d.evaluate(hash: pageA, now: 0), .none)
        XCTAssertEqual(d.evaluate(hash: pageA, now: 0.5), .none)
        // Page A is replaced at 0.75, before it ever settled. Its 0.75s of stillness must not
        // carry over: measured from 0 the next frame would settle, measured from 0.75 it can't.
        XCTAssertEqual(d.evaluate(hash: pageB, now: 0.75), .none)
        XCTAssertEqual(d.evaluate(hash: pageB, now: 1.5), .none)
        XCTAssertEqual(d.evaluate(hash: pageB, now: 2.0), .pageSettled(hash: pageB))
        XCTAssertEqual(d.settledCount, 1)
        XCTAssertEqual(d.rejectedCandidateCount, 1, "page A was abandoned before it settled")
    }

    func testHeartbeatResendDoesNotReopenACandidate() {
        var d = detector(heartbeat: 5)
        let page: UInt64 = 0x00
        XCTAssertEqual(d.evaluate(hash: page, now: 0), .none)
        XCTAssertEqual(d.evaluate(hash: page, now: 1), .pageSettled(hash: page))
        // The gate force-sends the unchanged scene at the heartbeat deadline. That's a timer
        // firing, not a page turn — the detector must not treat it as a new candidate…
        XCTAssertEqual(d.evaluate(hash: page, now: 6), .none)
        // …and the page must not settle a second time off the back of it.
        XCTAssertEqual(d.evaluate(hash: page, now: 8), .none)
        XCTAssertEqual(d.settledCount, 1)
    }

    func testTwoPagesInSequenceSettleTwice() {
        var d = detector()
        let pageA: UInt64 = 0x0000_0000_0000_0000
        let pageB: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
        _ = d.evaluate(hash: pageA, now: 0)
        XCTAssertEqual(d.evaluate(hash: pageA, now: 1), .pageSettled(hash: pageA))
        _ = d.evaluate(hash: pageB, now: 5)
        XCTAssertEqual(d.evaluate(hash: pageB, now: 6), .pageSettled(hash: pageB))
        XCTAssertEqual(d.settledCount, 2)
    }

    func testResetClearsState() {
        var d = detector()
        _ = d.evaluate(hash: 0x00, now: 0)
        _ = d.evaluate(hash: 0x00, now: 1)
        XCTAssertEqual(d.settledCount, 1)
        d.reset()
        XCTAssertEqual(d.settledCount, 0)
        XCTAssertEqual(d.rejectedCandidateCount, 0)
        XCTAssertFalse(d.isSettling)
        // After reset the same page is new again — a resumed session re-captures where it is.
        XCTAssertEqual(d.evaluate(hash: 0x00, now: 2), .none)
        XCTAssertEqual(d.evaluate(hash: 0x00, now: 3), .pageSettled(hash: 0x00))
    }

    // MARK: - Fixture images

    /// A page: white sheet with dark "text" bars in the given eighths of its height.
    private func pageImage(barRows: [Int], size: CGFloat = 64) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            UIColor.black.setFill()
            let rowHeight = size / 8
            for row in barRows {
                ctx.fill(CGRect(x: size * 0.1, y: CGFloat(row) * rowHeight + rowHeight * 0.2,
                                width: size * 0.8, height: rowHeight * 0.6))
            }
        }
    }

    /// Mid-turn: both pages' text smeared together at half strength — the frame you get while the
    /// page is physically moving.
    private func smearedImage(size: CGFloat = 64) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            UIColor(white: 0.5, alpha: 1).setFill()
            let rowHeight = size / 8
            for row in 0..<8 {
                ctx.fill(CGRect(x: size * 0.1, y: CGFloat(row) * rowHeight + rowHeight * 0.2,
                                width: size * 0.8, height: rowHeight * 0.6))
            }
        }
    }

    /// A hand across the book.
    private func occludedImage(size: CGFloat = 64) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(x: 0, y: size * 0.2, width: size * 0.7, height: size * 0.6))
        }
    }

    func testFixtureSequencePageBlurOcclusionPageSettlesOnlyRealPages() throws {
        let pageA = try XCTUnwrap(PerceptualHash.dhash(pageImage(barRows: [0, 1, 2, 3])))
        let pageB = try XCTUnwrap(PerceptualHash.dhash(pageImage(barRows: [4, 5, 6, 7])))
        let smear = try XCTUnwrap(PerceptualHash.dhash(smearedImage()))
        let hand = try XCTUnwrap(PerceptualHash.dhash(occludedImage()))

        var d = detector()
        var settled: [UInt64] = []
        // (hash, timestamp) — page A held, then a turn: smear, hand, smear in quick succession,
        // then page B held. Nothing transient survives a full second.
        let frames: [(UInt64, TimeInterval)] = [
            (pageA, 0.0), (pageA, 0.5), (pageA, 1.0), (pageA, 1.5),
            (smear, 2.0), (hand, 2.3), (smear, 2.6),
            (pageB, 3.0), (pageB, 3.5), (pageB, 4.0), (pageB, 4.5)
        ]
        for (hash, now) in frames {
            if case .pageSettled(let h) = d.evaluate(hash: hash, now: now) { settled.append(h) }
        }

        XCTAssertEqual(settled, [pageA, pageB], "only the two pages that held still may reach OCR")
        XCTAssertGreaterThan(d.rejectedCandidateCount, 0, "the transients should have been rejected")
    }
}
