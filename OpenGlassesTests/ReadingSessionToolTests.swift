import XCTest
@testable import OpenGlasses

/// Tests `ReadingSessionTool` (docs/plans/BT-reading-companion.md P2) and the reading Spotlight
/// adapter. Headless — the tool drives an injected service with a temp-directory store.
@MainActor
final class ReadingSessionToolTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeTool() -> (ReadingSessionTool, ReadingCompanionService, ReadingSessionStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-tool-\(UUID().uuidString)", isDirectory: true)
        let store = ReadingSessionStore(directory: dir)
        let service = ReadingCompanionService()
        service.store = store
        service.clock = { self.t0 }
        service.ocr = { _ in "text" }
        return (ReadingSessionTool(service: service), service, store)
    }

    func testStartRequiresATitle() async throws {
        let (tool, service, _) = makeTool()
        let out = try await tool.execute(args: ["action": "start"])
        XCTAssertTrue(out.contains("Which book?"))
        XCTAssertFalse(service.isActive)
    }

    func testStartOpensASessionUnderANormalisedBookID() async throws {
        let (tool, service, store) = makeTool()
        _ = try await tool.execute(args: ["action": "start", "book": "The Hobbit!"])
        XCTAssertTrue(service.isActive)
        XCTAssertEqual(store.sessions.first?.bookID, "the-hobbit")
        XCTAssertEqual(store.sessions.first?.bookTitle, "The Hobbit!")
    }

    func testPauseResumeAndStatus() async throws {
        let (tool, service, _) = makeTool()
        let noSession = try await tool.execute(args: ["action": "pause"])
        XCTAssertTrue(noSession.contains("No reading session"))

        _ = try await tool.execute(args: ["action": "start", "book": "Dune"])
        let paused = try await tool.execute(args: ["action": "pause"])
        XCTAssertTrue(paused.contains("Paused"))
        XCTAssertTrue(service.isPaused)
        let pausedStatus = try await tool.execute(args: ["action": "status"])
        XCTAssertTrue(pausedStatus.contains("Paused Dune"))

        let resumed = try await tool.execute(args: ["action": "resume"])
        XCTAssertTrue(resumed.contains("Following along"))
        XCTAssertFalse(service.isPaused)
        let status = try await tool.execute(args: ["action": "status"])
        XCTAssertTrue(status.contains("Reading Dune — 0 pages"))
    }

    func testStatusWithNoSession() async throws {
        let (tool, _, _) = makeTool()
        let out = try await tool.execute(args: ["action": "status"])
        XCTAssertTrue(out.contains("No reading session"))
    }

    func testWhereWasIScopesToTheNamedBook() async throws {
        let (tool, _, store) = makeTool()
        let s = store.startSession(bookID: "dune", bookTitle: "Dune", at: t0)
        store.appendPage(text: "A beginning is a very delicate time, said the Princess Irulan.",
                         dHash: 0x1, at: t0.addingTimeInterval(60), to: s.id)

        let out = try await tool.execute(args: ["action": "where_was_i", "book": "Dune"])
        XCTAssertTrue(out.contains("1 page into Dune"))
        let unread = try await tool.execute(args: ["action": "where_was_i", "book": "Unread Book"])
        XCTAssertTrue(unread.contains("haven't read anything"))
    }

    /// The tool moves the session between states; the book's content is answered from the injected
    /// context block. Saying so in the description is what keeps the model from calling this to
    /// "look something up" mid-chapter.
    func testDescriptionSteersContentQuestionsAwayFromTheToolAndStatesTheSpoilerRule() {
        let (tool, _, _) = makeTool()
        XCTAssertTrue(tool.description.contains("Do NOT use this to answer questions about the book's content"))
        XCTAssertTrue(tool.description.contains("Never reveal anything past the pages the reader has read"))
        XCTAssertEqual(tool.name, "reading_session")
    }
}

/// Reading sessions in the Spotlight index (Plan BQ content type, Plan BT producer).
final class ReadingSpotlightAdapterTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func session(pages: [String], title: String = "The Hobbit", id: String = "s1") -> ReadingSession {
        ReadingSession(id: id, bookID: "hobbit", bookTitle: title, startedAt: t0,
                       pages: pages.enumerated().map { i, text in
                           PageCapture(pageIndex: i, text: text, capturedAt: t0, dHash: UInt64(i))
                       })
    }

    func testSessionBecomesOneFindableRecord() throws {
        let records = SiriContentAdapters.readingSessions([session(pages: ["first page", "second page"])])
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.contentType, .readingSession)
        XCTAssertEqual(record.itemId, "s1")
        XCTAssertEqual(record.title, "The Hobbit — 2 pages")
        XCTAssertEqual(record.text, "first page\nsecond page")
        XCTAssertTrue(record.keywords.contains("The Hobbit"))
        XCTAssertEqual(record.date, t0)
        XCTAssertEqual(record.id, "reading_session:s1")
    }

    func testSinglePageTitleIsSingular() throws {
        let records = SiriContentAdapters.readingSessions([session(pages: ["only page"])])
        XCTAssertEqual(records.first?.title, "The Hobbit — 1 page")
    }

    /// A Spotlight hit with nothing behind it is worse than no hit.
    func testSessionsWithNothingReadableAreNotIndexed() {
        XCTAssertTrue(SiriContentAdapters.readingSessions([session(pages: [])]).isEmpty)
        XCTAssertTrue(SiriContentAdapters.readingSessions([session(pages: ["", "  "])]).isEmpty)
    }

    /// The reader's own captured pages of their own book — no reason to make them opt in, unlike
    /// conversations and field sessions.
    func testReadingIsDefaultOnAndCarriesALabel() {
        XCTAssertTrue(SiriContentType.readingSession.defaultEnabled)
        XCTAssertEqual(SiriContentType.readingSession.displayLabel, "Reading Sessions")
        XCTAssertEqual(SiriContentType.readingSession.rawValue, "reading_session")
        XCTAssertTrue(SiriContentType.allCases.contains(.readingSession))
    }
}
