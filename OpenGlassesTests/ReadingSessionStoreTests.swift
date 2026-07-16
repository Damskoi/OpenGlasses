import XCTest
@testable import OpenGlasses

/// Tests `ReadingSessionStore` (docs/plans/BT-reading-companion.md P1): book-scoped page ordering,
/// the two dedup signals, derived stats, and reload from disk. Temp directory. Headless.
@MainActor
final class ReadingSessionStoreTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("reading-\(UUID().uuidString)", isDirectory: true)
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// Long enough to clear the text-dedup floor.
    private func pageText(_ marker: String) -> String {
        "\(marker) — it was the best of times, it was the worst of times, it was the age of wisdom."
    }

    // MARK: - Pages

    func testPageIndexIsBookScopedAndContinuesAcrossSessions() {
        let store = ReadingSessionStore(directory: tempDir())
        let s1 = store.startSession(bookID: "book", bookTitle: "Book", at: t0)
        store.appendPage(text: pageText("one"), dHash: 0x1, at: at(1), to: s1.id)
        store.appendPage(text: pageText("two"), dHash: 0xFF00, at: at(2), to: s1.id)
        store.endSession(id: s1.id, at: at(3))

        // Tuesday's sitting continues Monday's page count rather than restarting it.
        let s2 = store.startSession(bookID: "book", bookTitle: "Book", at: at(100))
        store.appendPage(text: pageText("three"), dHash: 0xFFFF_0000, at: at(101), to: s2.id)

        XCTAssertEqual(store.pages(forBook: "book").map(\.pageIndex), [0, 1, 2])
        XCTAssertEqual(store.pages(forBook: "book").last?.text, pageText("three"))
    }

    func testSeparateBooksNumberIndependently() {
        let store = ReadingSessionStore(directory: tempDir())
        let a = store.startSession(bookID: "a", bookTitle: "A", at: t0)
        let b = store.startSession(bookID: "b", bookTitle: "B", at: t0)
        store.appendPage(text: pageText("a1"), dHash: 0x1, at: at(1), to: a.id)
        store.appendPage(text: pageText("b1"), dHash: 0xFF00, at: at(1), to: b.id)
        XCTAssertEqual(store.pages(forBook: "a").map(\.pageIndex), [0])
        XCTAssertEqual(store.pages(forBook: "b").map(\.pageIndex), [0])
    }

    func testDuplicateHashIsRejected() {
        let store = ReadingSessionStore(directory: tempDir(), duplicateHashDistance: 2)
        let s = store.startSession(bookID: "book", bookTitle: "Book", at: t0)
        XCTAssertNotNil(store.appendPage(text: pageText("one"), dHash: 0x0000_0000_0000_0000, at: at(1), to: s.id))
        // Looking back at the page just read: near-identical hash → not a new page.
        XCTAssertNil(store.appendPage(text: pageText("one again"), dHash: 0x0000_0000_0000_0001, at: at(2), to: s.id))
        XCTAssertEqual(store.pages(forBook: "book").count, 1)
    }

    func testDuplicateTextFromADifferentAngleIsRejected() {
        let store = ReadingSessionStore(directory: tempDir())
        let s = store.startSession(bookID: "book", bookTitle: "Book", at: t0)
        store.appendPage(text: pageText("one"), dHash: 0x0000_0000_0000_0000, at: at(1), to: s.id)
        // Same page re-read from further away: the hash drifted well past the threshold, but the
        // text is the same page's text — and line-wrapping differences must not defeat the match.
        let rewrapped = pageText("one").replacingOccurrences(of: " ", with: "\n")
        XCTAssertNil(store.appendPage(text: rewrapped, dHash: 0xFFFF_FFFF_FFFF_FFFF, at: at(2), to: s.id))
        XCTAssertEqual(store.pages(forBook: "book").count, 1)
    }

    func testShortOrEmptyTextIsNotTreatedAsDuplicate() {
        let store = ReadingSessionStore(directory: tempDir())
        let s = store.startSession(bookID: "book", bookTitle: "Book", at: t0)
        // Two distinct pages whose OCR came back empty: matching text here means "OCR found
        // nothing", not "same page", so the hash must be the only thing that can dedup them.
        XCTAssertNotNil(store.appendPage(text: "", dHash: 0x0000_0000_0000_0000, at: at(1), to: s.id))
        XCTAssertNotNil(store.appendPage(text: "", dHash: 0xFFFF_FFFF_FFFF_FFFF, at: at(2), to: s.id))
        XCTAssertEqual(store.pages(forBook: "book").count, 2)
    }

    func testAppendToUnknownSessionReturnsNil() {
        let store = ReadingSessionStore(directory: tempDir())
        XCTAssertNil(store.appendPage(text: pageText("x"), dHash: 0x1, at: t0, to: "nope"))
    }

    // MARK: - Stats

    func testStatsAreDerivedPerBook() {
        let store = ReadingSessionStore(directory: tempDir())
        let s1 = store.startSession(bookID: "book", bookTitle: "Book", at: t0)
        store.appendPage(text: pageText("1"), dHash: 0x1, at: at(1), to: s1.id)
        store.appendPage(text: pageText("2"), dHash: 0xFF00, at: at(2), to: s1.id)
        store.endSession(id: s1.id, at: at(10))                      // 10 minutes, 2 pages

        let s2 = store.startSession(bookID: "book", bookTitle: "Book", at: at(100))
        store.appendPage(text: pageText("3"), dHash: 0xFFFF_0000, at: at(101), to: s2.id)
        store.endSession(id: s2.id, at: at(110))                     // 10 minutes, 1 page

        let stats = try? XCTUnwrap(store.stats(forBook: "book"))
        XCTAssertEqual(stats?.sessionCount, 2)
        XCTAssertEqual(stats?.pageCount, 3)
        XCTAssertEqual(stats?.totalMinutes ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(stats?.pagesPerMinute ?? 0, 0.15, accuracy: 0.001)
        XCTAssertEqual(stats?.lastReadAt, at(110))
        XCTAssertEqual(stats?.bookTitle, "Book")
    }

    func testStatsNilForUnknownBook() {
        let store = ReadingSessionStore(directory: tempDir())
        XCTAssertNil(store.stats(forBook: "never-read"))
    }

    func testOpenSessionIsMeasuredToItsLastPageNotForever() {
        let store = ReadingSessionStore(directory: tempDir())
        let s = store.startSession(bookID: "book", bookTitle: "Book", at: t0)
        store.appendPage(text: pageText("1"), dHash: 0x1, at: at(5), to: s.id)
        // Never ended — the reader wandered off. Time stops at the last page, not at "now".
        XCTAssertEqual(store.session(id: s.id)?.durationMinutes ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(store.session(id: s.id)?.isActive, true)
    }

    func testEmptySessionHasNoDurationOrPace() {
        let store = ReadingSessionStore(directory: tempDir())
        let s = store.startSession(bookID: "book", bookTitle: "Book", at: t0)
        XCTAssertEqual(store.session(id: s.id)?.durationMinutes ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(store.session(id: s.id)?.pagesPerMinute ?? -1, 0, accuracy: 0.001)
    }

    func testBooksAreMostRecentlyReadFirst() {
        let store = ReadingSessionStore(directory: tempDir())
        store.startSession(bookID: "old", bookTitle: "Old", at: t0)
        store.startSession(bookID: "new", bookTitle: "New", at: at(100))
        store.startSession(bookID: "old", bookTitle: "Old", at: at(200))
        XCTAssertEqual(store.books().map(\.id), ["old", "new"])
    }

    // MARK: - Persistence

    func testReloadPersistsSessionsPagesAndFullWidthHashes() {
        let dir = tempDir()
        // A dHash uses all 64 bits, so the JSON round-trip must not route it through a Double.
        let bigHash: UInt64 = .max
        let store = ReadingSessionStore(directory: dir)
        let s = store.startSession(bookID: "book", bookTitle: "Book", at: t0)
        store.appendPage(text: pageText("1"), dHash: bigHash, at: at(1), to: s.id)
        store.appendPage(text: pageText("2"), dHash: 0xF0F0_F0F0_F0F0_F0F0, at: at(2), to: s.id)
        store.endSession(id: s.id, at: at(3))

        let reloaded = ReadingSessionStore(directory: dir)
        XCTAssertEqual(reloaded.sessions.count, 1)
        XCTAssertEqual(reloaded.pages(forBook: "book").map(\.dHash), [bigHash, 0xF0F0_F0F0_F0F0_F0F0])
        XCTAssertEqual(reloaded.session(id: s.id)?.endedAt, at(3))
        XCTAssertEqual(reloaded.stats(forBook: "book")?.pageCount, 2)
    }

    func testDeleteSessionAndBook() {
        let store = ReadingSessionStore(directory: tempDir())
        let s1 = store.startSession(bookID: "a", bookTitle: "A", at: t0)
        store.startSession(bookID: "a", bookTitle: "A", at: at(10))
        store.startSession(bookID: "b", bookTitle: "B", at: at(20))

        store.deleteSession(id: s1.id)
        XCTAssertEqual(store.sessions(forBook: "a").count, 1)

        store.deleteBook(id: "a")
        XCTAssertNil(store.stats(forBook: "a"))
        XCTAssertEqual(store.books().map(\.id), ["b"])
    }
}
