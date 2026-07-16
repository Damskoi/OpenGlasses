import XCTest
@testable import OpenGlasses

/// Tests `BookAlignmentIndex` (docs/plans/BT-reading-companion.md P4): locating noisy OCR captures
/// in a canonical text. Deterministic — no clock, no randomness, fixtures built from a synthetic
/// "book" whose every page is distinct. Headless.
final class BookAlignmentTests: XCTestCase {

    /// A synthetic book: `pages` pages of `wordsPerPage` distinct words each ("w0 w1 w2 …"),
    /// so every position is unambiguous and expected offsets are exact.
    private func book(pages: Int = 20, wordsPerPage: Int = 50) -> String {
        (0..<(pages * wordsPerPage)).map { "w\($0)" }.joined(separator: " ")
    }

    private func page(_ index: Int, wordsPerPage: Int = 50) -> String {
        ((index * wordsPerPage)..<((index + 1) * wordsPerPage)).map { "w\($0)" }.joined(separator: " ")
    }

    // MARK: - Clean matches

    func testExactPageMatchesAtTheRightPositionWithHighConfidence() throws {
        let index = BookAlignmentIndex(text: book())
        let match = try XCTUnwrap(index.align(captureText: page(7)))
        XCTAssertEqual(match.wordRange.lowerBound, 350)
        XCTAssertEqual(match.wordRange.count, 50)
        XCTAssertGreaterThan(match.confidence, 0.9)
        XCTAssertEqual(match.progress, 400.0 / 1000.0, accuracy: 0.001)
    }

    func testCaseAndPunctuationDoNotDefeatTheMatch() throws {
        let index = BookAlignmentIndex(text: "It was a bright cold day in April and the clocks were striking thirteen again")
        // OCR mangles case and punctuation; the vote must not care.
        let match = try XCTUnwrap(index.align(captureText: "BRIGHT, cold day! in april and THE clocks were striking"))
        XCTAssertEqual(match.wordRange.lowerBound, 3)
        XCTAssertGreaterThan(match.confidence, 0.8)
    }

    // MARK: - Noise

    /// The asymmetry the whole feature rests on: a capture with a quarter of its words mangled —
    /// which kills three quarters of its shingles — still locates, even though it would be poor
    /// grounding text.
    func testNoisyCaptureStillLocates() throws {
        let index = BookAlignmentIndex(text: book())
        let words = page(7).split(separator: " ").enumerated().map { i, word in
            i % 4 == 0 ? "garbled\(i)" : String(word)   // every 4th word destroyed
        }
        let match = try XCTUnwrap(index.align(captureText: words.joined(separator: " ")))
        // Location is right even with heavy damage…
        XCTAssertEqual(match.wordRange.lowerBound, 350)
        // …and the confidence honestly reflects the damage.
        XCTAssertLessThan(match.confidence, 0.6)
    }

    func testTextNotInTheBookDoesNotMatch() {
        let index = BookAlignmentIndex(text: book())
        XCTAssertNil(index.align(captureText: "completely unrelated prose about sailing ships and distant harbors tonight"))
    }

    func testTooShortACaptureDoesNotMatch() {
        let index = BookAlignmentIndex(text: book())
        XCTAssertNil(index.align(captureText: "w350 w351 w352"))
    }

    /// Common phrases repeat throughout a book; only distinctive runs may vote, so a capture of
    /// nothing but boilerplate must not pin itself to an arbitrary occurrence.
    func testNonDistinctiveShinglesAreDroppedFromTheIndex() {
        let refrain = Array(repeating: "said the old man again and", count: 40).joined(separator: " ")
        let index = BookAlignmentIndex(text: refrain)
        XCTAssertNil(index.align(captureText: "said the old man again and said the old man again"))
    }

    func testAmbiguousCapturePicksTheDenserCluster() throws {
        // "alpha beta gamma" appears twice, but the capture's other words only exist at the
        // second site — the vote must land there.
        let text = "alpha beta gamma one two three four five six seven eight nine "
            + "filler0 filler1 filler2 filler3 filler4 filler5 filler6 filler7 "
            + "alpha beta gamma unique1 unique2 unique3 unique4 unique5 unique6 unique7 unique8 unique9"
        let index = BookAlignmentIndex(text: text)
        let match = try XCTUnwrap(index.align(captureText: "alpha beta gamma unique1 unique2 unique3 unique4 unique5"))
        XCTAssertEqual(match.wordRange.lowerBound, 20)
    }

    // MARK: - Slices

    func testSliceReturnsOriginalTextWithPunctuationAndCase() {
        let index = BookAlignmentIndex(text: "One ring, to RULE them all — and in the darkness bind them.")
        XCTAssertEqual(index.slice(wordRange: 0..<3), "One ring, to")
        XCTAssertEqual(index.slice(wordRange: 10..<13), "darkness bind them.")
    }

    func testSliceClampsOutOfRangeRequests() {
        let index = BookAlignmentIndex(text: "just five words right here")
        XCTAssertEqual(index.slice(wordRange: 3..<99), "right here")
        XCTAssertEqual(index.slice(wordRange: 80..<99), "")
    }

    func testEmptyReferenceNeverMatches() {
        let index = BookAlignmentIndex(text: "")
        XCTAssertEqual(index.wordCount, 0)
        XCTAssertNil(index.align(captureText: "anything at all here to try and match today"))
    }
}
