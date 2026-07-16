import UIKit
import XCTest
@testable import OpenGlasses

/// Tests the BT P3 surfaces (streaks, HUD card, Config knobs) and P4 reference wiring (store
/// references, canonical grounding in the context builder, progress in recaps). Headless.
@MainActor
final class ReadingP3P4Tests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    private let calendar = Calendar(identifier: .gregorian)

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("reading-p34-\(UUID().uuidString)", isDirectory: true)
    }

    private func day(_ offset: Int) -> Date { t0.addingTimeInterval(Double(offset) * 86_400) }

    // MARK: - Streaks (P3)

    func testStreakCountsConsecutiveDaysBackFromToday() {
        let dates = [day(0), day(-1), day(-2), day(-5)]   // gap at -3
        XCTAssertEqual(ReadingStreaks.current(sessionDates: dates, calendar: calendar, today: t0), 3)
    }

    /// Reading yesterday but not yet today keeps the streak — the day isn't over.
    func testStreakSurvivesUntilAFullDayIsMissed() {
        XCTAssertEqual(ReadingStreaks.current(sessionDates: [day(-1), day(-2)], calendar: calendar, today: t0), 2)
        XCTAssertEqual(ReadingStreaks.current(sessionDates: [day(-2), day(-3)], calendar: calendar, today: t0), 0)
    }

    func testStreakEdgeCases() {
        XCTAssertEqual(ReadingStreaks.current(sessionDates: [], calendar: calendar, today: t0), 0)
        // Several sittings in one day are one streak day.
        let sameDay = [t0, t0.addingTimeInterval(3600), t0.addingTimeInterval(7200)]
        XCTAssertEqual(ReadingStreaks.current(sessionDates: sameDay, calendar: calendar, today: t0), 1)
    }

    // MARK: - HUD card (P3)

    func testRecapCardCarriesProgressSittingsAndStreak() throws {
        let stats = ReadingStats(bookID: "b", bookTitle: "The Hobbit", sessionCount: 3, pageCount: 42,
                                 totalMinutes: 90, pagesPerMinute: 0.47, lastReadAt: t0)
        let card = try XCTUnwrap(ReadingHUDCard.notification(stats: stats, progress: 0.34, streak: 5))
        XCTAssertEqual(card.title, "The Hobbit")
        XCTAssertTrue(card.body.contains("42 pages read"))
        XCTAssertTrue(card.body.contains("about 34% through"))
        XCTAssertTrue(card.body.contains("3 sittings"))
        XCTAssertTrue(card.body.contains("5-day streak"))
    }

    func testRecapCardOmitsWhatItCannotSay() throws {
        let stats = ReadingStats(bookID: "b", bookTitle: "New Book", sessionCount: 1, pageCount: 1,
                                 totalMinutes: 2, pagesPerMinute: 0.5, lastReadAt: t0)
        let card = try XCTUnwrap(ReadingHUDCard.notification(stats: stats, progress: nil, streak: 1))
        XCTAssertEqual(card.body, "1 page read")

        let empty = ReadingStats(bookID: "b", bookTitle: "B", sessionCount: 0, pageCount: 0,
                                 totalMinutes: 0, pagesPerMinute: 0, lastReadAt: nil)
        XCTAssertNil(ReadingHUDCard.notification(stats: empty))
    }

    // MARK: - Config knobs (P3)

    func testReadingDetectorKnobsDefaultToTheShippedTuning() {
        XCTAssertEqual(Config.readingHammingThreshold, 3)
        XCTAssertEqual(Config.readingStabilityWindowSeconds, 1.0, accuracy: 0.0001)
        XCTAssertEqual(Config.readingMinimumFrameInterval, 0.5, accuracy: 0.0001)
    }

    // MARK: - Store references (P4)

    func testReferenceRoundTripsAndDrivesProgress() {
        let dir = tempDir()
        let store = ReadingSessionStore(directory: dir)
        let s = store.startSession(bookID: "hobbit", bookTitle: "The Hobbit", at: t0)
        store.attachReference(BookReference(bookID: "hobbit", documentId: "doc1",
                                            documentName: "hobbit.pdf", wordCount: 1000, attachedAt: t0))

        let index = BookAlignmentIndex(text: (0..<1000).map { "w\($0)" }.joined(separator: " "))
        let match = index.align(captureText: (300..<350).map { "w\($0)" }.joined(separator: " "))
        store.appendPage(text: "long enough raw ocr text for the dedup floor to be satisfied here",
                         dHash: 0x1, at: t0, to: s.id, alignment: match)

        XCTAssertEqual(store.alignedFrontier(forBook: "hobbit"), 350)
        XCTAssertEqual(store.progress(forBook: "hobbit") ?? 0, 0.35, accuracy: 0.001)
        store.endSession(id: s.id, at: t0.addingTimeInterval(60))

        let reloaded = ReadingSessionStore(directory: dir)
        XCTAssertEqual(reloaded.reference(forBook: "hobbit")?.documentName, "hobbit.pdf")
        XCTAssertEqual(reloaded.pages(forBook: "hobbit").first?.alignedRange, 300..<350)
        XCTAssertEqual(reloaded.progress(forBook: "hobbit") ?? 0, 0.35, accuracy: 0.001)

        reloaded.detachReference(forBook: "hobbit")
        XCTAssertNil(reloaded.reference(forBook: "hobbit"))
        XCTAssertNil(reloaded.progress(forBook: "hobbit"), "no reference → no progress claim")
    }

    func testProgressNilWithoutAlignments() {
        let store = ReadingSessionStore(directory: tempDir())
        store.startSession(bookID: "b", bookTitle: "B", at: t0)
        store.attachReference(BookReference(bookID: "b", documentId: "d", documentName: "b.pdf",
                                            wordCount: 500, attachedAt: t0))
        XCTAssertNil(store.progress(forBook: "b"), "a reference with no aligned pages proves nothing")
    }

    // MARK: - Canonical grounding (P4)

    private func alignedPage(_ index: Int, raw: String, start: Int, count: Int) -> PageCapture {
        PageCapture(pageIndex: index, text: raw, capturedAt: t0.addingTimeInterval(Double(index) * 60),
                    dHash: UInt64(index), alignedStart: start, alignedWordCount: count,
                    alignedConfidence: 0.9)
    }

    func testAlignedPagesGroundOnCanonicalTextNotRawOCR() throws {
        let reference = BookAlignmentIndex(text: (0..<200).map { "canon\($0)" }.joined(separator: " "))
        let pages = [alignedPage(0, raw: "garbled ocr nonsense that should never reach the prompt at all",
                                 start: 0, count: 50)]
        let block = try XCTUnwrap(ReadingContextBuilder.block(
            bookTitle: "Book", pages: pages, reference: reference))
        XCTAssertTrue(block.contains("canon0 canon1"), "the canonical slice grounds the page")
        XCTAssertFalse(block.contains("garbled ocr nonsense"), "raw OCR is superseded when aligned")
        XCTAssertTrue(block.contains("about 25% of the way through"), "frontier 50 of 200 words")
        XCTAssertTrue(block.contains(ReadingContextBuilder.spoilerRule))
    }

    /// The structural spoiler guarantee, P4 edition: the block can never carry canonical text
    /// past the furthest camera-proven position.
    func testCanonicalTextPastTheFrontierNeverAppears() throws {
        let reference = BookAlignmentIndex(text: (0..<200).map { "canon\($0)" }.joined(separator: " "))
        let pages = [alignedPage(0, raw: "raw text one long enough to pass the emptiness filter",
                                 start: 0, count: 50),
                     alignedPage(1, raw: "raw text two long enough to pass the emptiness filter",
                                 start: 50, count: 50)]
        let block = try XCTUnwrap(ReadingContextBuilder.block(
            bookTitle: "Book", pages: pages, reference: reference))
        XCTAssertTrue(block.contains("canon99"), "up to the frontier ships")
        XCTAssertFalse(block.contains("canon100"), "one word past the frontier must not exist in the block")
        XCTAssertFalse(block.contains("canon150"))
    }

    func testUnalignedPagesKeepRawOCRAlongsideAlignedOnes() throws {
        let reference = BookAlignmentIndex(text: (0..<200).map { "canon\($0)" }.joined(separator: " "))
        let pages = [alignedPage(0, raw: "aligned page raw ocr goes unused entirely here today",
                                 start: 0, count: 30),
                     PageCapture(pageIndex: 1, text: "unaligned page keeps its raw ocr text as grounding",
                                 capturedAt: t0.addingTimeInterval(60), dHash: 0x2)]
        let block = try XCTUnwrap(ReadingContextBuilder.block(
            bookTitle: "Book", pages: pages, reference: reference))
        XCTAssertTrue(block.contains("canon0"))
        XCTAssertTrue(block.contains("unaligned page keeps its raw ocr"))
    }

    func testNoReferenceMeansTodayBehaviorUnchanged() throws {
        let pages = [alignedPage(0, raw: "raw ocr stays the grounding when no reference is attached",
                                 start: 0, count: 30)]
        let block = try XCTUnwrap(ReadingContextBuilder.block(bookTitle: "Book", pages: pages))
        XCTAssertTrue(block.contains("raw ocr stays the grounding"))
        XCTAssertFalse(block.contains("% of the way through"))
    }

    /// Flashcards built from garbled OCR quiz the reader on the garbling — aligned pages feed
    /// the deck their canonical slice.
    func testDeckSourceUsesCanonicalSlicesWhenAligned() {
        let reference = BookAlignmentIndex(text: (0..<100).map { "canon\($0)" }.joined(separator: " "))
        let session = ReadingSession(
            bookID: "b", bookTitle: "B", startedAt: t0,
            pages: [alignedPage(0, raw: "garbled ocr text long enough to be kept", start: 0, count: 5)])
        XCTAssertEqual(ReadingRecapBuilder.deckSource(session: session, reference: reference),
                       "[p1] canon0 canon1 canon2 canon3 canon4")
        XCTAssertEqual(ReadingRecapBuilder.deckSource(session: session),
                       "[p1] garbled ocr text long enough to be kept",
                       "no reference → raw OCR, unchanged")
    }

    // MARK: - Catch-up: read 1–3 with the app, 4–9 without, 10+ with it (P4)

    private func gapScenario() -> (store: ReadingSessionStore, sessionID: String, reference: BookAlignmentIndex) {
        let store = ReadingSessionStore(directory: tempDir())
        let reference = BookAlignmentIndex(text: (0..<6000).map { "w\($0)" }.joined(separator: " "))
        store.attachReference(BookReference(bookID: "book", documentId: "d", documentName: "b.epub",
                                            wordCount: 6000, attachedAt: t0))
        let s = store.startSession(bookID: "book", bookTitle: "Book", at: t0)
        // Chapters 1–3 with the app…
        store.appendPage(text: "early chapter text long enough for the dedup floor", dHash: 0x1,
                         at: t0, to: s.id,
                         alignment: .init(wordRange: 0..<500, confidence: 0.9, progress: 500 / 6000))
        // …4–9 read on the couch (nothing captured)… then back at chapter 10 with the app.
        store.appendPage(text: "chapter ten text long enough for the dedup floor too", dHash: 0xFF00,
                         at: t0.addingTimeInterval(60), to: s.id,
                         alignment: .init(wordRange: 4500..<5000, confidence: 0.9, progress: 5000 / 6000))
        return (store, s.id, reference)
    }

    func testGapScenarioDetectsTheUnconfirmedStretch() {
        let (store, _, _) = gapScenario()
        XCTAssertEqual(store.unconfirmedGap(forBook: "book"), 500..<4500)
        // The gap surfaces as an instruction to ASK, not as content and not as a wrong denial.
        let block = ReadingContextBuilder.block(
            bookTitle: "Book", pages: store.pages(forBook: "book"),
            unconfirmedGap: store.unconfirmedGap(forBook: "book"))
        XCTAssertTrue(block?.contains("neither captured nor confirmed") == true)
        XCTAssertTrue(block?.contains("ask whether they've read it") == true)
    }

    func testCaughtUpAssertionClosesTheGapAndUnlocksRetrieval() {
        let (store, _, reference) = gapScenario()
        // "I've read up to here" — clamped to the camera frontier (5000), never past it.
        XCTAssertEqual(store.assertCaughtUp(forBook: "book"), 5000)
        XCTAssertNil(store.unconfirmedGap(forBook: "book"), "assertion covers the 4–9 stretch")

        // A question about the offline-read middle now retrieves its passage…
        let slices = reference.retrieve(query: "what about w2500 again", upTo: 5000)
        XCTAssertTrue(slices.contains { $0.contains("w2500") })
        // …but retrieval can never reach past the mark, even for a matching query.
        let beyond = reference.retrieve(query: "tell me about w5500", upTo: 5000)
        XCTAssertFalse(beyond.contains { $0.contains("w5500") },
                       "the clamp is the spoiler rule — no text past the camera-proven position")
    }

    func testAssertCaughtUpNeedsAFrontierAndIsMonotonic() {
        let store = ReadingSessionStore(directory: tempDir())
        store.attachReference(BookReference(bookID: "b", documentId: "d", documentName: "b.pdf",
                                            wordCount: 1000, attachedAt: t0))
        XCTAssertNil(store.assertCaughtUp(forBook: "b"), "no aligned capture → no 'here' to assert")

        let s = store.startSession(bookID: "b", bookTitle: "B", at: t0)
        store.appendPage(text: "a page long enough for the dedup floor to pass", dHash: 0x1,
                         at: t0, to: s.id,
                         alignment: .init(wordRange: 100..<150, confidence: 0.9, progress: 0.15))
        XCTAssertEqual(store.assertCaughtUp(forBook: "b"), 150)

        // Read further with the app, then assert again after another offline stretch: it rises.
        store.appendPage(text: "another distinct page also long enough for the floor", dHash: 0xFFFF_0000,
                         at: t0.addingTimeInterval(60), to: s.id,
                         alignment: .init(wordRange: 400..<450, confidence: 0.9, progress: 0.45))
        XCTAssertEqual(store.assertCaughtUp(forBook: "b"), 450, "assertions are cumulative, never lower")
    }

    func testRetrievalSectionRequiresCoveredRangesAndTurn() {
        let (store, _, reference) = gapScenario()
        store.assertCaughtUp(forBook: "book")
        let pages = store.pages(forBook: "book")
        let covered = store.coveredRanges(forBook: "book")

        let withTurn = ReadingContextBuilder.block(
            bookTitle: "Book", pages: pages, reference: reference,
            assertedReadUpTo: 5000, retrievalRanges: covered, turn: "remind me about w2500")
        XCTAssertTrue(withTurn?.contains("Earlier in the book") == true)
        XCTAssertTrue(withTurn?.contains("w2500") == true)

        let withoutTurn = ReadingContextBuilder.block(
            bookTitle: "Book", pages: pages, reference: reference,
            assertedReadUpTo: 5000, retrievalRanges: covered)
        XCTAssertFalse(withoutTurn?.contains("Earlier in the book") == true)
    }

    /// Without the assertion, the big offline-read hole is NOT covered (4000 words is far past
    /// the interpolation limit), so its content stays out of the prompt even for a matching
    /// question — inference never fills large gaps.
    func testLargeGapStaysUncoveredWithoutAssertion() {
        let (store, _, reference) = gapScenario()
        let covered = store.coveredRanges(forBook: "book")
        XCTAssertEqual(covered, [0..<500, 4500..<5000], "the 4–9 stretch is not covered")

        let block = ReadingContextBuilder.block(
            bookTitle: "Book", pages: store.pages(forBook: "book"), reference: reference,
            retrievalRanges: covered, turn: "remind me about w2500")
        XCTAssertFalse(block?.contains("w2500 ") == true)
    }

    // MARK: - Small-hole interpolation (P4)

    /// The camera blinked on a page mid-sitting (blur, empty OCR, a false dedup drop): a hole
    /// smaller than the interpolation limit, flanked by captures from the SAME sitting, counts
    /// as read — its content is retrievable without any assertion.
    func testMissedPageWithinASittingIsInterpolated() {
        let store = ReadingSessionStore(directory: tempDir())
        let reference = BookAlignmentIndex(text: (0..<2000).map { "w\($0)" }.joined(separator: " "))
        store.attachReference(BookReference(bookID: "book", documentId: "d", documentName: "b.epub",
                                            wordCount: 2000, attachedAt: t0))
        let s = store.startSession(bookID: "book", bookTitle: "Book", at: t0)
        store.appendPage(text: "page before the missed one long enough for dedup", dHash: 0x1,
                         at: t0, to: s.id,
                         alignment: .init(wordRange: 0..<500, confidence: 0.9, progress: 0.25))
        // …one page missed (hole 500..<700, 200 words)…
        store.appendPage(text: "page after the missed one also long enough here", dHash: 0xFF00,
                         at: t0.addingTimeInterval(120), to: s.id,
                         alignment: .init(wordRange: 700..<1200, confidence: 0.9, progress: 0.6))

        XCTAssertEqual(store.coveredRanges(forBook: "book"), [0..<1200],
                       "the small same-sitting hole is interpolated into one covered range")
        XCTAssertNil(store.unconfirmedGap(forBook: "book"), "a blink is not a gap to nag about")

        // A question about the missed page's content retrieves its canonical text.
        let block = ReadingContextBuilder.block(
            bookTitle: "Book", pages: store.pages(forBook: "book"), reference: reference,
            retrievalRanges: store.coveredRanges(forBook: "book"), turn: "what was w600 about")
        XCTAssertTrue(block?.contains("w600 ") == true, "the blinked page grounds via interpolation")
    }

    /// The two boundaries interpolation must respect: size, and sitting.
    func testInterpolationRespectsSizeAndSessionBoundaries() {
        let store = ReadingSessionStore(directory: tempDir())
        store.attachReference(BookReference(bookID: "book", documentId: "d", documentName: "b.pdf",
                                            wordCount: 10_000, attachedAt: t0))

        // Same sitting, hole of 900 words (> 800 limit): NOT interpolated.
        let s1 = store.startSession(bookID: "book", bookTitle: "Book", at: t0)
        store.appendPage(text: "first captured page long enough for the dedup floor", dHash: 0x1,
                         at: t0, to: s1.id,
                         alignment: .init(wordRange: 0..<300, confidence: 0.9, progress: 0.03))
        store.appendPage(text: "second captured page long enough for the dedup floor", dHash: 0xFF00,
                         at: t0.addingTimeInterval(60), to: s1.id,
                         alignment: .init(wordRange: 1200..<1500, confidence: 0.9, progress: 0.15))
        XCTAssertEqual(store.coveredRanges(forBook: "book"), [0..<300, 1200..<1500],
                       "a hole past the size limit is never inferred read")
        store.endSession(id: s1.id, at: t0.addingTimeInterval(120))

        // NEXT sitting starts a small distance past the last capture: still NOT interpolated —
        // there's no continuity evidence across sittings, however small the hole.
        let s2 = store.startSession(bookID: "book", bookTitle: "Book", at: t0.addingTimeInterval(86_400))
        store.appendPage(text: "next sitting's first page long enough for dedup", dHash: 0xFFFF_0000,
                         at: t0.addingTimeInterval(86_460), to: s2.id,
                         alignment: .init(wordRange: 1700..<2000, confidence: 0.9, progress: 0.2))
        XCTAssertEqual(store.coveredRanges(forBook: "book"), [0..<300, 1200..<1500, 1700..<2000],
                       "the 200-word hole between sittings stays uncovered — that's the assertion's job")
    }

    // MARK: - Recap progress (P4)

    func testResumeRecapSpeaksProgressWhenKnown() throws {
        let stats = ReadingStats(bookID: "b", bookTitle: "The Hobbit", sessionCount: 2, pageCount: 10,
                                 totalMinutes: 30, pagesPerMinute: 0.33, lastReadAt: t0)
        let recap = try XCTUnwrap(ReadingRecapBuilder.resumeRecap(
            stats: stats, lastPageText: nil, progress: 0.34))
        XCTAssertTrue(recap.contains("about 34% of the way through"))

        let justStarted = try XCTUnwrap(ReadingRecapBuilder.resumeRecap(
            stats: stats, lastPageText: nil, progress: 0.004))
        XCTAssertTrue(justStarted.contains("just started the book"),
                      "sub-1% must not round to a discouraging 0%")

        let noReference = try XCTUnwrap(ReadingRecapBuilder.resumeRecap(
            stats: stats, lastPageText: nil))
        XCTAssertFalse(noReference.contains("way through"))
    }

    // MARK: - Service alignment lifecycle (P4)

    func testServiceAlignsCapturesOnceIndexIsReady() async {
        let dir = tempDir()
        let store = ReadingSessionStore(directory: dir)
        let service = ReadingCompanionService()
        service.store = store
        service.clock = { self.t0 }
        service.ocr = { _ in (100..<150).map { "w\($0)" }.joined(separator: " ") }
        store.attachReference(BookReference(bookID: "book", documentId: "doc1",
                                            documentName: "book.pdf", wordCount: 1000, attachedAt: t0))
        service.loadReferenceText = { documentId in
            documentId == "doc1" ? (0..<1000).map { "w\($0)" }.joined(separator: " ") : nil
        }

        _ = await service.start(bookID: "book", bookTitle: "Book")
        await service.alignmentPreparation?.value

        // Drive a settle through the test seam (change, then stillness past the window).
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 32))
        }
        var now = t0
        service.clock = { now }
        service.handleFrame(image)
        now = t0.addingTimeInterval(2)
        service.handleFrame(image)
        await Task.yield(); await Task.yield()

        let page = store.pages(forBook: "book").first
        XCTAssertEqual(page?.alignedRange, 100..<150, "the capture aligns to its true position")
        XCTAssertEqual(store.progress(forBook: "book") ?? 0, 0.15, accuracy: 0.001)
    }
}
