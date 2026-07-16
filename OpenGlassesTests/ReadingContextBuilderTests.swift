import XCTest
@testable import OpenGlasses

/// Tests `ReadingContextBuilder` (docs/plans/BT-reading-companion.md P1): the spoiler rule ships on
/// every block, the recency window stays verbatim while older pages condense, and the whole thing
/// respects its character budget. Headless.
final class ReadingContextBuilderTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func page(_ index: Int, _ text: String) -> PageCapture {
        PageCapture(pageIndex: index, text: text, capturedAt: t0.addingTimeInterval(Double(index) * 60),
                    dHash: UInt64(index))
    }

    /// `count` pages of filler, each tagged so we can assert which survived.
    private func pages(_ count: Int, charactersEach: Int = 500) -> [PageCapture] {
        (0..<count).map { i in
            let filler = String(repeating: "lorem ipsum dolor sit amet ", count: charactersEach / 27 + 1)
            return page(i, "MARK\(i) " + String(filler.prefix(charactersEach)))
        }
    }

    // MARK: - Nothing to say

    func testNilWhenNoPages() {
        XCTAssertNil(ReadingContextBuilder.block(bookTitle: "Book", pages: []))
    }

    func testNilWhenEveryPageOCRedToNothing() {
        let blank = [page(0, ""), page(1, "   \n  ")]
        XCTAssertNil(ReadingContextBuilder.block(bookTitle: "Book", pages: blank))
    }

    func testNilWhenBudgetCannotCarryTheRulePlusAPage() {
        // Too small to hold the spoiler rule and a usable slice of the page. A rule with no
        // evidence under it would be worse than no block at all, so nothing is emitted.
        XCTAssertNil(ReadingContextBuilder.block(bookTitle: "Book", pages: pages(3), budgetCharacters: 300))
    }

    // MARK: - Spoiler rule

    func testBlockCarriesTheSpoilerRuleAndTheReadersPosition() throws {
        let block = try XCTUnwrap(ReadingContextBuilder.block(bookTitle: "Dune", pages: pages(4)))
        XCTAssertTrue(block.contains(ReadingContextBuilder.spoilerRule))
        XCTAssertTrue(block.contains("\"Dune\""))
        XCTAssertTrue(block.contains("4 page(s) seen so far"))
        XCTAssertTrue(block.contains("p4 is where they are now"))
    }

    func testBlockCannotContainAPageTheReaderHasNotSeen() throws {
        // The structural half of the spoiler guarantee: the builder only ever sees read pages, so
        // unread text has no path into the turn even if the model is asked for it.
        let read = Array(pages(6).prefix(3))
        let block = try XCTUnwrap(ReadingContextBuilder.block(bookTitle: "Book", pages: read))
        XCTAssertTrue(block.contains("MARK2"))
        XCTAssertFalse(block.contains("MARK3"))
        XCTAssertFalse(block.contains("MARK5"))
    }

    // MARK: - Windowing

    func testRecentPagesAreVerbatimAndOlderPagesCondense() throws {
        let block = try XCTUnwrap(ReadingContextBuilder.block(
            bookTitle: "Book", pages: pages(6, charactersEach: 300),
            recentPages: 2, budgetCharacters: 4000, excerptCharacters: 60))

        XCTAssertTrue(block.contains("Most recent pages (verbatim):"))
        XCTAssertTrue(block.contains("Earlier pages (condensed):"))
        // The two most recent pages arrive whole…
        XCTAssertTrue(block.contains("[p6] MARK5"))
        XCTAssertTrue(block.contains("[p5] MARK4"))
        // …and an older page arrives as a marked-off excerpt, not in full.
        XCTAssertTrue(block.contains("- p1: MARK0"))
        XCTAssertTrue(block.contains("…"))
        let condensedLine = try XCTUnwrap(block.split(separator: "\n").first { $0.hasPrefix("- p1:") })
        XCTAssertLessThan(condensedLine.count, 100)
    }

    func testOCRBlanksAreSkippedButNumberingStillReflectsWhatWasSeen() throws {
        // p2's OCR failed. It stays in the store (a page really was turned) but can't ground an
        // answer, so it drops out here — and the gap in numbering is the honest record of that.
        let mixed = [page(0, "the opening lines of the book, quite legible"),
                     page(1, ""),
                     page(2, "the third page, also legible")]
        let block = try XCTUnwrap(ReadingContextBuilder.block(bookTitle: "Book", pages: mixed, recentPages: 3))
        XCTAssertTrue(block.contains("[p1]"))
        XCTAssertFalse(block.contains("[p2]"))
        XCTAssertTrue(block.contains("[p3]"))
        XCTAssertTrue(block.contains("2 page(s) seen so far"))
    }

    func testPagesAreOrderedByIndexRegardlessOfInputOrder() throws {
        let shuffled = [page(2, "third"), page(0, "first"), page(1, "second")]
        let block = try XCTUnwrap(ReadingContextBuilder.block(bookTitle: "Book", pages: shuffled, recentPages: 3))
        let first = try XCTUnwrap(block.range(of: "[p1] first"))
        let second = try XCTUnwrap(block.range(of: "[p2] second"))
        let third = try XCTUnwrap(block.range(of: "[p3] third"))
        XCTAssertTrue(first.lowerBound < second.lowerBound)
        XCTAssertTrue(second.lowerBound < third.lowerBound)
    }

    func testVerbatimTextIsWhitespaceNormalised() throws {
        let block = try XCTUnwrap(ReadingContextBuilder.block(
            bookTitle: "Book", pages: [page(0, "a line\nbroken by\n  the printer")], recentPages: 1))
        XCTAssertTrue(block.contains("[p1] a line broken by the printer"))
    }

    // MARK: - Budget

    func testLongCorpusStaysWithinBudgetAndKeepsTheCurrentPage() throws {
        let budget = 2000
        let block = try XCTUnwrap(ReadingContextBuilder.block(
            bookTitle: "Book", pages: pages(50), budgetCharacters: budget))

        XCTAssertLessThanOrEqual(block.count, budget)
        XCTAssertTrue(block.contains("[p50] MARK49"), "the page the reader is on must always ship")
        XCTAssertTrue(block.contains(ReadingContextBuilder.spoilerRule))
        XCTAssertFalse(block.contains("MARK0"), "the oldest pages must have been dropped to fit")
        XCTAssertTrue(block.contains("dropped to fit"), "dropped pages must be declared, not hidden")
    }

    func testHugeCurrentPageIsTruncatedRatherThanDropped() throws {
        let budget = 1500
        let block = try XCTUnwrap(ReadingContextBuilder.block(
            bookTitle: "Book", pages: [page(0, "MARK0 " + String(repeating: "x", count: 20_000))],
            budgetCharacters: budget))
        XCTAssertLessThanOrEqual(block.count, budget)
        XCTAssertTrue(block.contains("[p1] MARK0"))
        XCTAssertTrue(block.hasSuffix("…"), "a cut page must be marked as cut")
    }

    /// Review finding: one giant unbroken token made the word-boundary cut land on the space
    /// inside the "[p1] " label, shipping a bare page number with zero content — the exact
    /// rule-with-no-evidence state the builder exists to prevent.
    func testUnbrokenTokenPageStillShipsContentNotABareLabel() throws {
        let budget = 1500
        let block = try XCTUnwrap(ReadingContextBuilder.block(
            bookTitle: "Book", pages: [page(0, String(repeating: "x", count: 20_000))],
            budgetCharacters: budget))
        XCTAssertLessThanOrEqual(block.count, budget)
        let verbatimLine = try XCTUnwrap(block.split(separator: "\n").first { $0.hasPrefix("[p1]") })
        XCTAssertGreaterThan(verbatimLine.count, 200,
                             "the page's content must ship, not just its label: \(verbatimLine.prefix(40))…")
        XCTAssertTrue(verbatimLine.contains("xxxx"))
    }

    func testBudgetIsRespectedAcrossAWideRangeOfSizes() {
        let corpus = pages(80)
        for budget in stride(from: 700, through: 20_000, by: 331) {
            guard let block = ReadingContextBuilder.block(
                bookTitle: "A Reasonably Long Book Title", pages: corpus, budgetCharacters: budget) else { continue }
            XCTAssertLessThanOrEqual(block.count, budget, "overflowed at budget \(budget)")
            XCTAssertTrue(block.contains("[p80]"), "lost the current page at budget \(budget)")
        }
    }

    func testGenerousBudgetKeepsEverything() throws {
        let block = try XCTUnwrap(ReadingContextBuilder.block(
            bookTitle: "Book", pages: pages(5, charactersEach: 200), budgetCharacters: 100_000))
        XCTAssertFalse(block.contains("dropped to fit"))
        for i in 0..<5 { XCTAssertTrue(block.contains("MARK\(i)"), "lost p\(i + 1)") }
    }
}
