import XCTest
@testable import OpenGlasses

/// Tests `ReadingRecapBuilder` (docs/plans/BT-reading-companion.md P2): the model-free recaps that
/// answer "where was I?" instantly and stand in when deck generation fails. Headless.
final class ReadingRecapBuilderTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func page(_ index: Int, _ text: String) -> PageCapture {
        PageCapture(pageIndex: index, text: text, capturedAt: t0.addingTimeInterval(Double(index) * 60),
                    dHash: UInt64(index))
    }

    private func stats(pages: Int, sessions: Int = 1, minutes: Double = 10) -> ReadingStats {
        ReadingStats(bookID: "b", bookTitle: "The Hobbit", sessionCount: sessions, pageCount: pages,
                     totalMinutes: minutes,
                     pagesPerMinute: minutes > 0 ? Double(pages) / minutes : 0,
                     lastReadAt: t0)
    }

    // MARK: - Resume recap

    func testResumeRecapStatesPositionAndLastRead() throws {
        let recap = try XCTUnwrap(ReadingRecapBuilder.resumeRecap(
            stats: stats(pages: 12, sessions: 3, minutes: 24),
            lastPageText: "Bilbo reached for the ring in his pocket."))
        XCTAssertTrue(recap.contains("12 pages into The Hobbit"))
        XCTAssertTrue(recap.contains("across 3 sittings"))
        XCTAssertTrue(recap.contains("Last thing you read:"))
        XCTAssertTrue(recap.contains("ring in his pocket"))
    }

    func testResumeRecapNilWithNothingRead() {
        XCTAssertNil(ReadingRecapBuilder.resumeRecap(stats: stats(pages: 0), lastPageText: nil))
    }

    func testResumeRecapSingularAndNoSittingsClauseForOneSitting() throws {
        let recap = try XCTUnwrap(ReadingRecapBuilder.resumeRecap(
            stats: stats(pages: 1, sessions: 1, minutes: 2), lastPageText: nil))
        XCTAssertTrue(recap.contains("1 page into"))
        XCTAssertFalse(recap.contains("pages into"))
        XCTAssertFalse(recap.contains("sittings"))
    }

    func testResumeRecapSurvivesMissingLastPage() throws {
        let recap = try XCTUnwrap(ReadingRecapBuilder.resumeRecap(
            stats: stats(pages: 5), lastPageText: nil))
        XCTAssertFalse(recap.contains("Last thing you read"))
        XCTAssertTrue(recap.contains("5 pages into"))
    }

    /// A pace derived from one page over two minutes extrapolates to nonsense; a spoken stat that's
    /// obviously wrong costs more trust than the stat was worth.
    func testPaceOnlyOnceThereIsEnoughToDeriveItFrom() throws {
        let thin = try XCTUnwrap(ReadingRecapBuilder.resumeRecap(
            stats: stats(pages: 2, minutes: 4), lastPageText: nil))
        XCTAssertFalse(thin.contains("a page"))

        let solid = try XCTUnwrap(ReadingRecapBuilder.resumeRecap(
            stats: stats(pages: 10, minutes: 20), lastPageText: nil))
        XCTAssertTrue(solid.contains("about 2 minutes a page"))
    }

    func testResumeRecapReadsBackTheEndOfThePageNotTheStart() throws {
        // The reader stopped at the bottom of the page — that's the line that places them.
        let long = String(repeating: "earlier words ", count: 60) + "and then the door opened."
        let recap = try XCTUnwrap(ReadingRecapBuilder.resumeRecap(
            stats: stats(pages: 4), lastPageText: long))
        XCTAssertTrue(recap.contains("and then the door opened."))
        XCTAssertTrue(recap.contains("…"))
    }

    // MARK: - Session recap

    func testSessionRecapPrefersTheDeckOverview() throws {
        let session = ReadingSession(bookID: "b", bookTitle: "The Hobbit", startedAt: t0,
                                     endedAt: t0.addingTimeInterval(1800),
                                     pages: [page(0, "one"), page(1, "two")])
        let recap = try XCTUnwrap(ReadingRecapBuilder.sessionRecap(
            session: session, overview: "Bilbo left the Shire.", keyPoints: ["He met the dwarves"]))
        XCTAssertTrue(recap.contains("2 pages of The Hobbit"))
        XCTAssertTrue(recap.contains("30 minutes"))
        XCTAssertTrue(recap.contains("Bilbo left the Shire."))
        XCTAssertTrue(recap.contains("- He met the dwarves"))
    }

    /// Offline, or generation failed — the recap still has to say something true.
    func testSessionRecapFallsBackToWhereTheyStoppedWithoutAModel() throws {
        let session = ReadingSession(bookID: "b", bookTitle: "The Hobbit", startedAt: t0,
                                     endedAt: t0.addingTimeInterval(600),
                                     pages: [page(0, "the last line of the sitting")])
        let recap = try XCTUnwrap(ReadingRecapBuilder.sessionRecap(session: session, overview: nil))
        XCTAssertTrue(recap.contains("1 page of The Hobbit"))
        XCTAssertTrue(recap.contains("You finished on:"))
        XCTAssertTrue(recap.contains("the last line of the sitting"))
    }

    func testSessionRecapNilWithNoPages() {
        let session = ReadingSession(bookID: "b", bookTitle: "The Hobbit", startedAt: t0)
        XCTAssertNil(ReadingRecapBuilder.sessionRecap(session: session, overview: nil))
    }

    func testEmptyOverviewIsTreatedAsAbsent() throws {
        let session = ReadingSession(bookID: "b", bookTitle: "The Hobbit", startedAt: t0,
                                     pages: [page(0, "a line")])
        let recap = try XCTUnwrap(ReadingRecapBuilder.sessionRecap(session: session, overview: "   "))
        XCTAssertTrue(recap.contains("You finished on:"))
    }

    // MARK: - Deck source

    func testDeckSourceCarriesOnlyThisSittingsPagesInOrder() throws {
        let session = ReadingSession(bookID: "b", bookTitle: "The Hobbit", startedAt: t0,
                                     pages: [page(2, "third"), page(0, "first"), page(1, "second")])
        let source = try XCTUnwrap(ReadingRecapBuilder.deckSource(session: session))
        XCTAssertEqual(source, "[p1] first\n\n[p2] second\n\n[p3] third")
    }

    func testDeckSourceSkipsUnreadablePagesAndIsNilWhenNoneReadable() {
        let mixed = ReadingSession(bookID: "b", bookTitle: "T", startedAt: t0,
                                   pages: [page(0, "readable"), page(1, "  ")])
        XCTAssertEqual(ReadingRecapBuilder.deckSource(session: mixed), "[p1] readable")

        let blank = ReadingSession(bookID: "b", bookTitle: "T", startedAt: t0, pages: [page(0, "")])
        XCTAssertNil(ReadingRecapBuilder.deckSource(session: blank))
    }

    /// The deck prompt is the spoiler rule's second front: a model that recognises the book will
    /// quiz the reader on chapters they haven't reached unless told the text is all there is.
    func testDeckPromptScopesTheModelToTheSuppliedPages() {
        let prompt = ReadingRecapBuilder.deckSystemPrompt(bookTitle: "The Hobbit")
        XCTAssertTrue(prompt.contains("The Hobbit"))
        XCTAssertTrue(prompt.contains("only the pages they read in this sitting"))
        XCTAssertTrue(prompt.lowercased().contains("do not use anything you know"))
        XCTAssertTrue(prompt.lowercased().contains("never reference, hint at or foreshadow"))
    }
}
