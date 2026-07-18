import XCTest
@testable import OpenGlasses

/// Plan BU — Offline Live Session P1: the pure turn loop, ask-time frame freshness, and the
/// per-turn prompt assembler. All headless — no mic, camera, model, or clock.
final class OfflineLiveSessionTests: XCTestCase {

    // MARK: - Turn loop: happy path

    func testHappyPathRunsThroughEveryPhaseAndBackToListening() {
        var loop = LiveSessionTurnLoop()
        XCTAssertEqual(loop.state, .idle)

        XCTAssertEqual(loop.handle(.start), [.startListening])
        XCTAssertEqual(loop.state, .listening)

        XCTAssertEqual(loop.handle(.speechDetected), [])
        XCTAssertEqual(loop.state, .transcribing)

        XCTAssertEqual(loop.handle(.transcript("what is this plant")),
                       [.beginInference(turn: "what is this plant")])
        XCTAssertEqual(loop.state, .inferring)

        XCTAssertEqual(loop.handle(.responseBegan), [])
        XCTAssertEqual(loop.state, .speaking)

        XCTAssertEqual(loop.handle(.speechCompleted), [])
        XCTAssertEqual(loop.state, .listening)
    }

    func testTranscriptDirectFromListeningStartsInference() {
        // Some STT stacks deliver a final transcript without a separate VAD onset.
        var loop = LiveSessionTurnLoop()
        _ = loop.handle(.start)
        XCTAssertEqual(loop.handle(.transcript("hello")), [.beginInference(turn: "hello")])
        XCTAssertEqual(loop.state, .inferring)
    }

    func testTranscriptIsTrimmed() {
        var loop = LiveSessionTurnLoop()
        _ = loop.handle(.start)
        XCTAssertEqual(loop.handle(.transcript("  read this sign  ")),
                       [.beginInference(turn: "read this sign")])
    }

    func testEmptyTranscriptReturnsToListeningWithoutInferring() {
        var loop = LiveSessionTurnLoop()
        _ = loop.handle(.start)
        _ = loop.handle(.speechDetected)
        XCTAssertEqual(loop.handle(.transcript("   ")), [])
        XCTAssertEqual(loop.state, .listening)
    }

    // MARK: - Turn loop: barge-in and supersede

    func testBargeInWhileSpeakingCancelsTTSAndReTranscribes() {
        var loop = LiveSessionTurnLoop()
        _ = loop.handle(.start)
        _ = loop.handle(.speechDetected)
        _ = loop.handle(.transcript("first question"))
        _ = loop.handle(.responseBegan)
        XCTAssertEqual(loop.state, .speaking)

        XCTAssertEqual(loop.handle(.speechDetected), [.cancelSpeech])
        XCTAssertEqual(loop.state, .transcribing)

        XCTAssertEqual(loop.handle(.transcript("actually, what about this")),
                       [.beginInference(turn: "actually, what about this")])
        XCTAssertEqual(loop.state, .inferring)
    }

    func testSpeechWhileInferringSupersedesPendingAnswer() {
        var loop = LiveSessionTurnLoop()
        _ = loop.handle(.start)
        _ = loop.handle(.speechDetected)
        _ = loop.handle(.transcript("slow question"))
        XCTAssertEqual(loop.state, .inferring)

        XCTAssertEqual(loop.handle(.speechDetected), [.cancelInference])
        XCTAssertEqual(loop.state, .transcribing)
    }

    // MARK: - Turn loop: cancel from every state

    func testCancelFromEveryStateReturnsToListeningAndUnwindsWork() {
        // idle: cancel is a no-op (nothing to abandon).
        var idle = LiveSessionTurnLoop()
        XCTAssertEqual(idle.handle(.cancel), [])
        XCTAssertEqual(idle.state, .idle)

        // listening: nothing in flight.
        var listening = loop(in: .listening)
        XCTAssertEqual(listening.handle(.cancel), [])
        XCTAssertEqual(listening.state, .listening)

        // transcribing: nothing in flight.
        var transcribing = loop(in: .transcribing)
        XCTAssertEqual(transcribing.handle(.cancel), [])
        XCTAssertEqual(transcribing.state, .listening)

        // inferring: cancel the inference.
        var inferring = loop(in: .inferring)
        XCTAssertEqual(inferring.handle(.cancel), [.cancelInference])
        XCTAssertEqual(inferring.state, .listening)

        // speaking: cancel the speech.
        var speaking = loop(in: .speaking)
        XCTAssertEqual(speaking.handle(.cancel), [.cancelSpeech])
        XCTAssertEqual(speaking.state, .listening)
    }

    // MARK: - Turn loop: stop from every state

    func testStopFromEveryActiveStateClosesMicAndUnwindsWork() {
        var listening = loop(in: .listening)
        XCTAssertEqual(listening.handle(.stop), [.stopListening])
        XCTAssertEqual(listening.state, .idle)

        var inferring = loop(in: .inferring)
        XCTAssertEqual(inferring.handle(.stop), [.cancelInference, .stopListening])
        XCTAssertEqual(inferring.state, .idle)

        var speaking = loop(in: .speaking)
        XCTAssertEqual(speaking.handle(.stop), [.cancelSpeech, .stopListening])
        XCTAssertEqual(speaking.state, .idle)
    }

    func testStopWhenIdleIsNoOp() {
        var loop = LiveSessionTurnLoop()
        XCTAssertEqual(loop.handle(.stop), [])
        XCTAssertEqual(loop.state, .idle)
    }

    // MARK: - Turn loop: guarded transitions

    func testStartIgnoredWhenNotIdle() {
        var loop = LiveSessionTurnLoop()
        _ = loop.handle(.start)
        XCTAssertEqual(loop.handle(.start), [])
        XCTAssertEqual(loop.state, .listening)
    }

    func testResponseBeganOnlyAppliesWhileInferring() {
        var loop = LiveSessionTurnLoop()
        _ = loop.handle(.start)
        XCTAssertEqual(loop.handle(.responseBegan), [])
        XCTAssertEqual(loop.state, .listening)
    }

    func testSpeechCompletedOnlyAppliesWhileSpeaking() {
        var loop = LiveSessionTurnLoop()
        _ = loop.handle(.start)
        XCTAssertEqual(loop.handle(.speechCompleted), [])
        XCTAssertEqual(loop.state, .listening)
    }

    func testTranscriptIgnoredWhileSpeaking() {
        // A stray transcript with no barge-in (no speechDetected) must not hijack the answer.
        var speaking = loop(in: .speaking)
        XCTAssertEqual(speaking.handle(.transcript("noise")), [])
        XCTAssertEqual(speaking.state, .speaking)
    }

    // MARK: - Frame freshness policy

    func testFreshnessNoFrameAlwaysRefreshes() {
        let policy = FrameFreshnessPolicy(maxAgeSeconds: 2)
        XCTAssertTrue(policy.needsFreshFrame(frameTimestamp: nil, now: 100))
    }

    func testFreshnessBoundaryIsInclusive() {
        let policy = FrameFreshnessPolicy(maxAgeSeconds: 2)
        // Exactly at the limit is still fresh.
        XCTAssertFalse(policy.needsFreshFrame(frameTimestamp: 98, now: 100))
        // Just past the limit is stale.
        XCTAssertTrue(policy.needsFreshFrame(frameTimestamp: 97.9, now: 100))
        // Well within the limit is fresh.
        XCTAssertFalse(policy.needsFreshFrame(frameTimestamp: 99.5, now: 100))
    }

    func testFreshnessFutureTimestampIsFresh() {
        let policy = FrameFreshnessPolicy(maxAgeSeconds: 2)
        XCTAssertFalse(policy.needsFreshFrame(frameTimestamp: 105, now: 100))
    }

    // MARK: - Turn assembler

    func testAssemblerWithoutPersonaIsJustTheGroundingRule() {
        let out = LiveTurnAssembler.systemPrompt(persona: nil)
        XCTAssertEqual(out, LiveTurnAssembler.groundingRule)

        let blank = LiveTurnAssembler.systemPrompt(persona: "   ")
        XCTAssertEqual(blank, LiveTurnAssembler.groundingRule)
    }

    func testAssemblerKeepsPersonaAndAlwaysIncludesGroundingRule() {
        let out = LiveTurnAssembler.systemPrompt(persona: "You are Ada, terse and dry.")
        XCTAssertTrue(out.contains("Ada"))
        XCTAssertTrue(out.contains(LiveTurnAssembler.groundingRule))
    }

    func testAssemblerClipsOversizedPersonaButNeverTheGroundingRule() {
        let hugePersona = String(repeating: "x", count: 5000)
        let out = LiveTurnAssembler.systemPrompt(persona: hugePersona, budgetCharacters: 800)
        // The grounding rule (the safety contract) survives intact...
        XCTAssertTrue(out.contains(LiveTurnAssembler.groundingRule))
        // ...and the persona was clipped rather than shipped whole.
        XCTAssertLessThan(out.count, 5000)
    }

    func testAssemblerGroundingRuleSurvivesEvenWhenBudgetIsTiny() {
        // Budget smaller than the grounding rule: persona has no room and is dropped whole.
        let out = LiveTurnAssembler.systemPrompt(persona: "some persona", budgetCharacters: 10)
        XCTAssertEqual(out, LiveTurnAssembler.groundingRule)
    }

    func testRollingWindowKeepsNewestAndDropsOldest() {
        let turns = [
            LiveTurnAssembler.Turn(role: .user, text: "one"),
            LiveTurnAssembler.Turn(role: .assistant, text: "two"),
            LiveTurnAssembler.Turn(role: .user, text: "three"),
            LiveTurnAssembler.Turn(role: .assistant, text: "four"),
        ]
        // Budget fits only the last two ("three" + "four" = (5+1) + (4+1) = 11); "two" would push
        // it to 15 and drops.
        let window = LiveTurnAssembler.rollingWindow(turns, budgetCharacters: 11)
        XCTAssertEqual(window.map(\.content), ["three", "four"])
        XCTAssertEqual(window.map(\.role), ["user", "assistant"])
    }

    func testRollingWindowSkipsEmptyTurns() {
        let turns = [
            LiveTurnAssembler.Turn(role: .user, text: "  "),
            LiveTurnAssembler.Turn(role: .assistant, text: "real"),
        ]
        let window = LiveTurnAssembler.rollingWindow(turns, budgetCharacters: 1000)
        XCTAssertEqual(window.map(\.content), ["real"])
    }

    func testAssembleProducesSystemPromptAndCappedHistory() {
        let turns = (0..<50).map {
            LiveTurnAssembler.Turn(role: $0.isMultiple(of: 2) ? .user : .assistant,
                                   text: "turn number \($0)")
        }
        let assembled = LiveTurnAssembler.assemble(persona: "Guide", priorTurns: turns,
                                                   historyBudgetCharacters: 60)
        XCTAssertTrue(assembled.systemPrompt.contains("Guide"))
        XCTAssertTrue(assembled.systemPrompt.contains(LiveTurnAssembler.groundingRule))
        // History is capped and the retained turns are the most recent ones.
        let totalChars = assembled.history.reduce(0) { $0 + $1.content.count + 1 }
        XCTAssertLessThanOrEqual(totalChars, 60)
        XCTAssertEqual(assembled.history.last?.content, "turn number 49")
    }

    // MARK: - Helpers

    /// Drive a fresh loop into `target` via the normal transition path so tests read against a
    /// realistic history rather than a poked private field.
    private func loop(in target: LiveSessionTurnLoop.State) -> LiveSessionTurnLoop {
        var loop = LiveSessionTurnLoop()
        guard target != .idle else { return loop }
        _ = loop.handle(.start)                       // → listening
        if target == .listening { return loop }
        _ = loop.handle(.speechDetected)              // → transcribing
        if target == .transcribing { return loop }
        _ = loop.handle(.transcript("q"))             // → inferring
        if target == .inferring { return loop }
        _ = loop.handle(.responseBegan)               // → speaking
        return loop
    }
}
