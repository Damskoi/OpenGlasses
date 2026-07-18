import XCTest
import UIKit
import MWDATCore
@testable import OpenGlasses

/// Plan BV P2 — the `PowerPolicyService` wiring (injected signal seams, posture publishing,
/// hysteresis across samples), the DAT thermal mapping, and the live-mode frame-throttle stretch.
final class PowerPolicyServiceTests: XCTestCase {

    // MARK: - DAT ThermalLevel → ThermalPressure

    func testGlassesThermalMapping() {
        XCTAssertEqual(ThermalPressure(MWDATCore.ThermalLevel.unknown), .nominal)
        XCTAssertEqual(ThermalPressure(MWDATCore.ThermalLevel.none), .nominal)
        XCTAssertEqual(ThermalPressure(MWDATCore.ThermalLevel.light), .nominal)
        XCTAssertEqual(ThermalPressure(MWDATCore.ThermalLevel.moderate), .fair)
        XCTAssertEqual(ThermalPressure(MWDATCore.ThermalLevel.severe), .serious)
        XCTAssertEqual(ThermalPressure(MWDATCore.ThermalLevel.critical), .critical)
        XCTAssertEqual(ThermalPressure(MWDATCore.ThermalLevel.emergency), .critical)
        XCTAssertEqual(ThermalPressure(MWDATCore.ThermalLevel.shutdown), .critical)
    }

    // MARK: - Service fusion & publishing

    @MainActor
    func testServiceFusesInjectedSignals() {
        let service = PowerPolicyService()
        service.glassesBatteryPercent = { 25 }
        service.update()
        XCTAssertEqual(service.posture, .conserve)
        XCTAssertEqual(service.explanation, "conserving — glasses battery 25%")
    }

    @MainActor
    func testServiceDefaultsToNormal() {
        let service = PowerPolicyService()
        service.update()
        XCTAssertEqual(service.posture, .normal)
        XCTAssertNil(service.explanation)
    }

    @MainActor
    func testChargingRelievesPhoneBattery() {
        let service = PowerPolicyService()
        service.phoneBatteryFraction = { 0.05 }
        service.phoneCharging = { true }
        service.update()
        XCTAssertEqual(service.posture, .normal)
    }

    // MARK: - Hysteresis across successive samples (service holds `previous`)

    @MainActor
    func testServiceHysteresisIsStickyAcrossUpdates() {
        let service = PowerPolicyService()
        var battery = 0.28
        service.phoneBatteryFraction = { battery }

        service.update()
        XCTAssertEqual(service.posture, .conserve)   // entered conserve at ≤0.30

        battery = 0.32                               // in the 0.30–0.35 hysteresis band
        service.update()
        XCTAssertEqual(service.posture, .conserve)   // ...stays conserve, doesn't flap

        battery = 0.40                               // clears the exit threshold
        service.update()
        XCTAssertEqual(service.posture, .normal)
    }

    // MARK: - Posture frame-interval multiplier

    func testFrameIntervalMultiplierByPosture() {
        XCTAssertEqual(PowerPosture.normal.frameIntervalMultiplier, 1.0)
        XCTAssertEqual(PowerPosture.conserve.frameIntervalMultiplier, 2.0)
        XCTAssertEqual(PowerPosture.reserve.frameIntervalMultiplier, 4.0)
    }

    // MARK: - FrameThrottler power stretch (deterministic via injected clock)

    func testThrottlerStretchesIntervalUnderPowerMultiplier() {
        var t = Date(timeIntervalSinceReferenceDate: 0)
        let throttler = FrameThrottler(interval: 10, now: { t })
        var forwarded = 0
        throttler.onThrottledFrame = { _ in forwarded += 1 }
        let frame = UIImage()

        // Multiplier 1.0: a frame at t=11 clears the 10s interval.
        throttler.submit(frame)                       // t=0 → forwarded (first frame)
        t = Date(timeIntervalSinceReferenceDate: 11)
        throttler.submit(frame)                       // t=11 → forwarded
        XCTAssertEqual(forwarded, 2)

        // Now stretch ×2 → effective interval 20s. A frame 15s later is dropped...
        throttler.powerIntervalMultiplier = 2.0
        t = Date(timeIntervalSinceReferenceDate: 26)
        throttler.submit(frame)                       // 26-11 = 15 < 20 → dropped
        XCTAssertEqual(forwarded, 2)
        // ...but at 20s+ it forwards again.
        t = Date(timeIntervalSinceReferenceDate: 32)
        throttler.submit(frame)                       // 32-11 = 21 ≥ 20 → forwarded
        XCTAssertEqual(forwarded, 3)
    }

    func testThrottlerMultiplierFlooredAtOne() {
        // A sub-1 multiplier must not *speed up* the stream.
        var t = Date(timeIntervalSinceReferenceDate: 0)
        let throttler = FrameThrottler(interval: 10, now: { t })
        throttler.powerIntervalMultiplier = 0.1
        var forwarded = 0
        throttler.onThrottledFrame = { _ in forwarded += 1 }
        let frame = UIImage()

        throttler.submit(frame)                       // t=0 → forwarded
        t = Date(timeIntervalSinceReferenceDate: 5)
        throttler.submit(frame)                       // 5 < 10 (floor) → dropped
        XCTAssertEqual(forwarded, 1)
    }
}
