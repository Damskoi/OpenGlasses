import XCTest
@testable import OpenGlasses

/// Tests the waveline's pure core: state fusion precedence and the motion math's invariants.
/// The rendering is decorative; what must not regress is which state wins and that the wave
/// stays anchored and phase-continuous. Headless.
final class VoiceWavelineTests: XCTestCase {

    // MARK: - State fusion

    /// Precedence: speaking > thinking > listening > idle — the most active thing wins the eye.
    func testFusionPrecedence() {
        XCTAssertEqual(VoiceVisualState.from(isSpeaking: true, isProcessing: true, isListening: true,
                                             realtimeActive: true), .speaking)
        XCTAssertEqual(VoiceVisualState.from(isSpeaking: false, isProcessing: true, isListening: true,
                                             realtimeActive: true), .thinking)
        XCTAssertEqual(VoiceVisualState.from(isSpeaking: false, isProcessing: false, isListening: true,
                                             realtimeActive: false), .listening)
        XCTAssertEqual(VoiceVisualState.from(isSpeaking: false, isProcessing: false, isListening: false,
                                             realtimeActive: false), .idle)
    }

    /// A realtime session's mic is always open — an active session that isn't speaking listens.
    func testRealtimeSessionReadsAsListening() {
        XCTAssertEqual(VoiceVisualState.from(isSpeaking: false, isProcessing: false, isListening: false,
                                             realtimeActive: true), .listening)
    }

    // MARK: - Motion math

    /// The end-pin envelope: the line is anchored at both edges at every time and in every state.
    func testDisplacementIsZeroAtBothEnds() {
        for state in [VoiceVisualState.idle, .listening, .thinking, .speaking] {
            let params = WavelineParams.params(for: state)
            for t in stride(from: 0.0, through: 10.0, by: 0.7) {
                XCTAssertEqual(WavelineParams.displacement(phase: 0, time: t, amplitudes: params), 0,
                               accuracy: 1e-9)
                XCTAssertEqual(WavelineParams.displacement(phase: 1, time: t, amplitudes: params), 0,
                               accuracy: 1e-9)
            }
        }
    }

    /// Displacement stays within the sum of amplitudes — the wave can't escape its lane.
    func testDisplacementIsBounded() {
        for state in [VoiceVisualState.idle, .listening, .thinking, .speaking] {
            let params = WavelineParams.params(for: state)
            let bound = params.slow + params.mid + params.fast + 1e-9
            for phase in stride(from: 0.0, through: 1.0, by: 0.02) {
                for t in stride(from: 0.0, through: 5.0, by: 0.3) {
                    let d = WavelineParams.displacement(phase: phase, time: t, amplitudes: params)
                    XCTAssertLessThanOrEqual(abs(d), bound, "escaped at phase \(phase), t \(t), \(state)")
                }
            }
        }
    }

    /// Every state has a distinct parameter set, ordered by energy: idle is the quietest,
    /// speaking the tallest — so the states are visually distinguishable by construction.
    func testStatesAreDistinctAndEnergyOrdered() {
        let energy: (VoiceVisualState) -> Double = { state in
            let p = WavelineParams.params(for: state)
            return p.slow + p.mid + p.fast
        }
        XCTAssertLessThan(energy(.idle), energy(.thinking))
        XCTAssertLessThan(energy(.thinking), energy(.speaking))
        let all = [VoiceVisualState.idle, .listening, .thinking, .speaking].map(WavelineParams.params(for:))
        XCTAssertEqual(Set(all.map { "\($0.slow)-\($0.mid)-\($0.fast)" }).count, 4, "no two states share params")
    }

    /// Strand offsets (constant phase shift + speed detune) never break the end-pin envelope:
    /// every thread of the ribbon stays anchored at both edges, whatever its offsets.
    func testStrandOffsetsStayAnchoredAndBounded() {
        let params = WavelineParams.params(for: .speaking)
        let bound = params.slow + params.mid + params.fast + 1e-9
        for shift in [0.0, 1.1, 2.1, 4.4] {
            for scale in [0.82, 0.94, 1.0, 1.18] {
                XCTAssertEqual(WavelineParams.displacement(phase: 0, time: 2.7, amplitudes: params,
                                                           phaseShift: shift, timeScale: scale), 0, accuracy: 1e-9)
                XCTAssertEqual(WavelineParams.displacement(phase: 1, time: 2.7, amplitudes: params,
                                                           phaseShift: shift, timeScale: scale), 0, accuracy: 1e-9)
                for phase in stride(from: 0.0, through: 1.0, by: 0.05) {
                    XCTAssertLessThanOrEqual(
                        abs(WavelineParams.displacement(phase: phase, time: 2.7, amplitudes: params,
                                                        phaseShift: shift, timeScale: scale)), bound)
                }
            }
        }
    }

    /// Phase continuity is structural: frequencies are static properties the states can't touch —
    /// blending amplitudes at fixed frequency can never jump the wave. This test documents the
    /// contract: a mid-transition blend of two states' params still respects the same bound.
    func testMidTransitionBlendStaysBoundedAndAnchored() {
        let a = WavelineParams.params(for: .idle)
        let b = WavelineParams.params(for: .speaking)
        let blended = WavelineParams(slow: (a.slow + b.slow) / 2,
                                     mid: (a.mid + b.mid) / 2,
                                     fast: (a.fast + b.fast) / 2)
        XCTAssertEqual(WavelineParams.displacement(phase: 0, time: 3.3, amplitudes: blended), 0, accuracy: 1e-9)
        let bound = blended.slow + blended.mid + blended.fast + 1e-9
        for phase in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertLessThanOrEqual(abs(WavelineParams.displacement(phase: phase, time: 3.3, amplitudes: blended)), bound)
        }
    }
}
