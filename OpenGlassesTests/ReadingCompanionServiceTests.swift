import XCTest
import UIKit
@testable import OpenGlasses

/// Tests `ReadingCompanionService` (docs/plans/BT-reading-companion.md P2): session lifecycle, the
/// frame → detector → OCR → store pipeline, the end-of-session artifacts, and the prompt block's
/// gating. Every collaborator is injected, so no camera, model or database is touched. Headless.
@MainActor
final class ReadingCompanionServiceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var now: Date = Date(timeIntervalSince1970: 1_000_000)

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("reading-svc-\(UUID().uuidString)", isDirectory: true)
    }

    /// A page: white sheet with dark "text" bars in the given eighths, so distinct pages hash apart.
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

    private func makeService(ocrText: @escaping (Int) -> String = { "page text number \($0), long enough to be a real page of prose" })
        -> (ReadingCompanionService, ReadingSessionStore) {
        let store = ReadingSessionStore(directory: tempDir())
        let service = ReadingCompanionService()
        service.store = store
        service.clock = { [unowned self] in self.now }
        var ocrCount = 0
        service.ocr = { _ in
            ocrCount += 1
            return ocrText(ocrCount)
        }
        return (service, store)
    }

    /// Drive frames until the detector settles: a change, then stillness past the window.
    private func settle(_ service: ReadingCompanionService, image: UIImage, from start: TimeInterval = 0) async {
        now = t0.addingTimeInterval(start)
        service.handleFrame(image)              // change → candidate
        now = t0.addingTimeInterval(start + 2)  // well past the 1s stability window
        service.handleFrame(image)              // stillness → settled
        await Task.yield()                      // let the OCR task finish
        await Task.yield()
    }

    // MARK: - Lifecycle

    func testStartOpensASessionAndAnnouncesTheBook() async {
        let (service, store) = makeService()
        let line = await service.start(bookID: "hobbit", bookTitle: "The Hobbit")
        XCTAssertTrue(service.isActive)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertTrue(line.contains("The Hobbit"))
    }

    func testStartOnAKnownBookRecapsWhereTheyWere() async {
        let (service, store) = makeService()
        let prior = store.startSession(bookID: "hobbit", bookTitle: "The Hobbit", at: t0)
        store.appendPage(text: "Bilbo went out of the door and down the lane.", dHash: 0x1,
                         at: t0.addingTimeInterval(60), to: prior.id)
        store.endSession(id: prior.id, at: t0.addingTimeInterval(600))

        let line = await service.start(bookID: "hobbit", bookTitle: "The Hobbit")
        XCTAssertTrue(line.contains("1 page into The Hobbit"), line)
        XCTAssertTrue(line.contains("down the lane"), line)
        // The sitting just opened must not be counted in the recap the reader hears.
        XCTAssertFalse(line.contains("sittings"), line)
    }

    func testStartIsIdempotent() async {
        let (service, store) = makeService()
        _ = await service.start(bookID: "a", bookTitle: "A")
        let second = await service.start(bookID: "b", bookTitle: "B")
        XCTAssertTrue(second.contains("Already reading"))
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testEndWithoutASessionSaysSo() async {
        let (service, _) = makeService()
        let line = await service.end()
        XCTAssertTrue(line.contains("No reading session"))
    }

    // MARK: - Frame pipeline

    func testSettledPageIsOCRedAndStored() async {
        let (service, store) = makeService()
        _ = await service.start(bookID: "hobbit", bookTitle: "The Hobbit")
        await settle(service, image: pageImage(barRows: [0, 1, 2]))

        XCTAssertEqual(service.pagesThisSession, 1)
        XCTAssertEqual(store.pages(forBook: "hobbit").count, 1)
        XCTAssertTrue(store.pages(forBook: "hobbit").first?.text.contains("page text number 1") == true)
    }

    func testTwoDistinctPagesBothLand() async {
        let (service, store) = makeService()
        _ = await service.start(bookID: "hobbit", bookTitle: "The Hobbit")
        await settle(service, image: pageImage(barRows: [0, 1, 2]), from: 0)
        await settle(service, image: pageImage(barRows: [5, 6, 7]), from: 10)
        XCTAssertEqual(store.pages(forBook: "hobbit").map(\.pageIndex), [0, 1])
    }

    /// A settled view we couldn't read is not a page the reader read — filing it would put a wall
    /// or a glare-blown page into their page count and wreck the pace stats.
    func testUnreadableCaptureIsCountedButNotStored() async {
        let (service, store) = makeService(ocrText: { _ in "   " })
        _ = await service.start(bookID: "hobbit", bookTitle: "The Hobbit")
        await settle(service, image: pageImage(barRows: [0, 1, 2]))

        XCTAssertEqual(store.pages(forBook: "hobbit").count, 0)
        XCTAssertEqual(service.pagesThisSession, 0)
        XCTAssertEqual(service.unreadableCaptures, 1)
    }

    func testFramesAreIgnoredWhilePausedAndResumeReCapturesTheCurrentPage() async {
        let (service, store) = makeService()
        _ = await service.start(bookID: "hobbit", bookTitle: "The Hobbit")
        service.pause()
        await settle(service, image: pageImage(barRows: [0, 1, 2]), from: 0)
        XCTAssertEqual(store.pages(forBook: "hobbit").count, 0, "paused must not capture")

        service.resume()
        await settle(service, image: pageImage(barRows: [0, 1, 2]), from: 20)
        XCTAssertEqual(store.pages(forBook: "hobbit").count, 1, "the book may have moved — re-read it")
    }

    func testFramesAreIgnoredWhenNoSessionIsRunning() async {
        let (service, store) = makeService()
        await settle(service, image: pageImage(barRows: [0, 1, 2]))
        XCTAssertEqual(store.sessions.count, 0)
    }

    /// The camera runs far faster than pages turn; everything upstream of this gate is skipped.
    func testFramesArrivingFasterThanTheFloorAreSkipped() async {
        let (service, store) = makeService()
        service.minimumFrameInterval = 5
        _ = await service.start(bookID: "hobbit", bookTitle: "The Hobbit")
        let image = pageImage(barRows: [0, 1, 2])

        now = t0
        service.handleFrame(image)                       // evaluated → candidate
        now = t0.addingTimeInterval(2)
        service.handleFrame(image)                       // inside the floor → skipped entirely
        await Task.yield()
        XCTAssertEqual(store.pages(forBook: "hobbit").count, 0)

        now = t0.addingTimeInterval(6)                   // past the floor → evaluated → settles
        service.handleFrame(image)
        await Task.yield(); await Task.yield()
        XCTAssertEqual(store.pages(forBook: "hobbit").count, 1)
    }

    // MARK: - Prompt context

    func testPromptContextIsNilWithoutALiveSessionAndCarriesPagesWithOne() async {
        let (service, _) = makeService()
        XCTAssertNil(service.promptContext(), "no session → the block must vanish")

        _ = await service.start(bookID: "hobbit", bookTitle: "The Hobbit")
        XCTAssertNil(service.promptContext(), "session with no pages yet → still nothing to ground on")

        await settle(service, image: pageImage(barRows: [0, 1, 2]))
        let block = service.promptContext()
        XCTAssertNotNil(block)
        XCTAssertTrue(block?.contains(ReadingContextBuilder.spoilerRule) == true)
        XCTAssertTrue(block?.contains("The Hobbit") == true)
    }

    func testPromptContextSurvivesPauseButNotEnd() async {
        let (service, _) = makeService()
        _ = await service.start(bookID: "hobbit", bookTitle: "The Hobbit")
        await settle(service, image: pageImage(barRows: [0, 1, 2]))

        service.pause()
        XCTAssertNotNil(service.promptContext(), "a paused reader still asks about the book")
        _ = await service.end()
        XCTAssertNil(service.promptContext())
    }

    // MARK: - End of session

    func testEndBuildsDeckSavesNoteAndIngestsOnlyTheActivityFact() async {
        let (service, _) = makeService()
        var deckCalls: [(system: String, text: String, source: String)] = []
        var notes: [(String, [String])] = []
        var facts: [(String, String)] = []

        service.generateDeck = { system, text, source in
            deckCalls.append((system, text, source))
            return StudyDeck(
                id: "d1", createdAt: Date(), source: source,
                summary: StudySummary(title: "Ch. 1", overview: "Bilbo left the Shire.",
                                      keyPoints: ["Met the dwarves"], docType: "novel"),
                flashcards: [Flashcard(front: "Who left?", back: "Bilbo")], quiz: [])
        }
        service.saveNote = { notes.append(($0, $1)) }
        service.ingestBrainFact = { facts.append(($0, $1)) }

        _ = await service.start(bookID: "hobbit", bookTitle: "The Hobbit")
        await settle(service, image: pageImage(barRows: [0, 1, 2]))
        now = t0.addingTimeInterval(1800)
        let recap = await service.end()

        // Deck generation is scoped to this sitting's pages, with the spoiler-scoped prompt.
        XCTAssertEqual(deckCalls.count, 1)
        XCTAssertTrue(deckCalls[0].system.contains("only the pages they read in this sitting"))
        XCTAssertTrue(deckCalls[0].text.contains("page text number 1"))
        XCTAssertEqual(deckCalls[0].source, "Reading: The Hobbit")

        XCTAssertTrue(recap.contains("Bilbo left the Shire."))
        XCTAssertTrue(recap.contains("- Met the dwarves"))

        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].1, ["reading", "The Hobbit"])
        XCTAssertTrue(notes[0].0.contains("Bilbo left the Shire."))

        // The brain gets the *activity*, never the prose — its extractor can't tell a novel's
        // characters from the reader's actual colleagues.
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].0, "Read 1 page(s) of The Hobbit.")
        XCTAssertEqual(facts[0].1, "The Hobbit")
        XCTAssertFalse(facts[0].0.contains("page text number 1"), "page prose must never reach the brain")

        XCTAssertFalse(service.isActive)
    }

    func testEndWithoutAModelStillRecapsAndSaves() async {
        let (service, _) = makeService()
        var notes: [(String, [String])] = []
        service.generateDeck = { _, _, _ in nil }   // offline / generation failed
        service.saveNote = { notes.append(($0, $1)) }

        _ = await service.start(bookID: "hobbit", bookTitle: "The Hobbit")
        await settle(service, image: pageImage(barRows: [0, 1, 2]))
        now = t0.addingTimeInterval(600)
        let recap = await service.end()

        XCTAssertTrue(recap.contains("1 page of The Hobbit"))
        XCTAssertTrue(recap.contains("You finished on:"))
        XCTAssertEqual(notes.count, 1)
    }

    func testEndWithNoPagesSkipsTheArtifacts() async {
        let (service, _) = makeService()
        var deckCalls = 0
        var notes = 0
        service.generateDeck = { _, _, _ in deckCalls += 1; return nil }
        service.saveNote = { _, _ in notes += 1 }

        _ = await service.start(bookID: "hobbit", bookTitle: "The Hobbit")
        let line = await service.end()

        XCTAssertTrue(line.contains("didn't catch any pages"))
        XCTAssertEqual(deckCalls, 0)
        XCTAssertEqual(notes, 0)
    }

    // MARK: - Where was I

    func testWhereWasIWorksBetweenSessionsAndFallsBackToTheLatestBook() async {
        let (service, store) = makeService()
        let s = store.startSession(bookID: "hobbit", bookTitle: "The Hobbit", at: t0)
        store.appendPage(text: "He never returned to Bag End before dark.", dHash: 0x1,
                         at: t0.addingTimeInterval(60), to: s.id)
        store.endSession(id: s.id, at: t0.addingTimeInterval(600))

        let recap = service.whereWasI()
        XCTAssertTrue(recap?.contains("1 page into The Hobbit") == true)
        XCTAssertTrue(recap?.contains("before dark") == true)
        XCTAssertNil(service.whereWasI(bookID: "never-opened"))
    }

    func testWhereWasINilWithNoHistory() {
        let (service, _) = makeService()
        XCTAssertNil(service.whereWasI())
    }
}

/// Book identity from a spoken title — one book, however the reader says it.
final class ReadingBookIDTests: XCTestCase {
    func testTitleVariantsCollapseToOneBook() {
        XCTAssertEqual(ReadingBookID.make(from: "The Hobbit"), "the-hobbit")
        XCTAssertEqual(ReadingBookID.make(from: "the hobbit"), "the-hobbit")
        XCTAssertEqual(ReadingBookID.make(from: "  The   Hobbit!  "), "the-hobbit")
        XCTAssertEqual(ReadingBookID.make(from: "The Hobbit"), ReadingBookID.make(from: "THE HOBBIT"))
    }

    func testDistinctTitlesStayDistinct() {
        XCTAssertNotEqual(ReadingBookID.make(from: "Dune"), ReadingBookID.make(from: "Dune Messiah"))
    }
}
