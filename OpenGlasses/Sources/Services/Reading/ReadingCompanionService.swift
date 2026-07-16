import Combine
import Foundation
import UIKit

/// Drives a live reading session (docs/plans/BT-reading-companion.md P2): glasses frames →
/// `PageTurnDetector` → OCR → `ReadingSessionStore`, plus the session's spoken bookends and the
/// grounding context each turn is answered from.
///
/// Every collaborator is an injected seam (OCR, deck generation, note + brain writes, the clock),
/// so the whole flow is unit-testable without a camera, a model, or a database — the same shape
/// `StudyService` uses.
@MainActor
final class ReadingCompanionService: ObservableObject {
    static let shared = ReadingCompanionService()

    @Published private(set) var isActive = false
    @Published private(set) var isPaused = false
    @Published private(set) var activeSessionID: String?
    @Published private(set) var pagesThisSession = 0

    /// Captures the detector called settled but OCR couldn't read. The number to watch on the P3
    /// device pass: a high count against a real book means the OCR/threshold tuning is off, not
    /// that the reader stopped turning pages.
    private(set) var unreadableCaptures = 0

    var store: ReadingSessionStore = .shared
    weak var presence: PresenceMonitor?
    private weak var camera: CameraService?

    /// Frame → recognized text. Set by `configure(...)`; tests inject a fake.
    var ocr: ((UIImage) async -> String)?
    /// (systemPrompt, text, source) → deck. Set by `configure(...)`; tests inject a fake.
    var generateDeck: ((String, String, String) async -> StudyDeck?)?
    /// (content, tags) → saved note.
    var saveNote: ((String, [String]) -> Void)?
    /// A one-line fact about the reader's activity — never page content. See `end()`.
    var ingestBrainFact: ((String, String) -> Void)?

    /// Injected clock — deterministic in tests.
    var clock: () -> Date = { Date() }
    /// Ceiling on the injected reading block. Sized for the on-device model, which is the tighter
    /// of the two budgets.
    var contextBudgetCharacters = 6000
    /// Floor on the gap between two evaluated frames. The camera runs far faster than pages turn,
    /// so this is the main battery lever: everything upstream of it is skipped, hashing included.
    var minimumFrameInterval: TimeInterval = 0.5

    private var detector = PageTurnDetector()
    private var frameSubscription: AnyCancellable?
    private var lastEvaluatedAt: TimeInterval?
    private var capturing = false

    init() {}

    /// No TTS seam here on purpose: every entry point returns its line to `ReadingSessionTool`, and
    /// the assistant speaks tool results already. A `speak` closure would be a second, silent path
    /// to the same speaker.
    func configure(camera: CameraService, study: StudyService) {
        self.camera = camera
        self.ocr = { image in
            guard let cg = image.cgImage else { return "" }
            return await OCRService().recognizeText(in: cg).text
        }
        self.generateDeck = { [weak study] systemPrompt, text, source in
            try? await study?.makeDeck(fromText: text, source: source, systemPrompt: systemPrompt)
        }
        self.saveNote = { content, tags in
            ContextualNoteStore.shared.save(ContextualNote(
                id: UUID().uuidString, content: content, tags: tags,
                latitude: nil, longitude: nil, locationName: nil, createdAt: Date()))
        }
        self.ingestBrainFact = { fact, book in
            BrainStore.shared.ingest(text: fact, sourceRef: book, sourceKind: "book")
        }
    }

    var activeSession: ReadingSession? {
        activeSessionID.flatMap { store.session(id: $0) }
    }

    // MARK: - Lifecycle

    /// Start reading `bookTitle`. Returns what to say: the "where was I?" recap when this book has
    /// history, an opening line when it doesn't.
    @discardableResult
    func start(bookID: String, bookTitle: String) async -> String {
        guard !isActive else { return "Already reading \(activeSession?.bookTitle ?? bookTitle)." }

        // Recap *before* opening the new session, or the session we just created would count itself
        // in "across N sittings" and the reader would hear a sitting they haven't had yet.
        let recap = store.stats(forBook: bookID).flatMap { stats in
            ReadingRecapBuilder.resumeRecap(
                stats: stats, lastPageText: store.pages(forBook: bookID).last?.text)
        }

        let session = store.startSession(bookID: bookID, bookTitle: bookTitle, at: clock())
        activeSessionID = session.id
        pagesThisSession = 0
        unreadableCaptures = 0
        isActive = true
        isPaused = false
        detector.reset()
        lastEvaluatedAt = nil

        await startFrames()
        return recap ?? "Reading \(bookTitle). I'll follow along."
    }

    func pause() {
        guard isActive, !isPaused else { return }
        isPaused = true
        // Keep the subscription: pause is a short interruption, and re-subscribing would make the
        // next frame look like the session's first, re-capturing the page already on the table.
    }

    func resume() {
        guard isActive, isPaused else { return }
        isPaused = false
        // The book may have moved while we weren't watching, so treat what's in front of us as new.
        detector.reset()
        lastEvaluatedAt = nil
    }

    /// End the session: recap spoken, note saved, deck built from *this sitting's* pages.
    @discardableResult
    func end() async -> String {
        guard isActive, let sessionID = activeSessionID else { return "No reading session is running." }

        frameSubscription?.cancel()
        frameSubscription = nil
        store.endSession(id: sessionID, at: clock())
        isActive = false
        isPaused = false
        activeSessionID = nil

        guard let session = store.session(id: sessionID), !session.pages.isEmpty else {
            return "Reading session ended — I didn't catch any pages."
        }

        var overview: String?
        var keyPoints: [String] = []
        if let text = ReadingRecapBuilder.deckSource(session: session), let generateDeck,
           let deck = await generateDeck(
            ReadingRecapBuilder.deckSystemPrompt(bookTitle: session.bookTitle),
            text,
            "Reading: \(session.bookTitle)") {
            overview = deck.summary.overview
            keyPoints = deck.summary.keyPoints
        }

        let recap = ReadingRecapBuilder.sessionRecap(
            session: session, overview: overview, keyPoints: keyPoints)
            ?? "Reading session ended."

        saveNote?(recap, ["reading", session.bookTitle])

        // Only the *activity* reaches the brain, never the prose. The brain is a graph of the
        // reader's own life — "who works at Acme", "when did I last see Alice" — and its extractor
        // can't tell a novel's characters from real people, so ingesting pages would file Bilbo
        // alongside the reader's colleagues. What's true and worth keeping is that they read this.
        ingestBrainFact?("Read \(session.pages.count) page(s) of \(session.bookTitle).",
                         session.bookTitle)
        return recap
    }

    // MARK: - Q&A

    /// "Where was I?" — answerable any time, without a live session.
    func whereWasI(bookID: String? = nil) -> String? {
        let book = bookID ?? activeSession?.bookID ?? store.books().first?.id
        guard let book, let stats = store.stats(forBook: book) else { return nil }
        return ReadingRecapBuilder.resumeRecap(
            stats: stats, lastPageText: store.pages(forBook: book).last?.text)
    }

    /// The grounding block for this turn, or `nil` when no session is live — the house
    /// `promptContext()` shape, injected unconditionally by `buildSystemPrompt` alongside the
    /// field-assist vault and active-project blocks.
    ///
    /// Deliberately *not* behind a classifier keyword list: a question mid-book is "who is she?" or
    /// "why did he do that?", which matches no keyword. The live session is the signal, and this
    /// nil is what gates it — the same reasoning the playbook context already runs on. Injecting at
    /// `buildSystemPrompt` also means local, cloud and cloud-agent paths are covered by one line,
    /// where a threaded parameter would inherit the two paths that silently drop `weatherContext`.
    func promptContext() -> String? {
        guard isActive, let session = activeSession else { return nil }
        return ReadingContextBuilder.block(
            bookTitle: session.bookTitle,
            pages: store.pages(forBook: session.bookID),
            budgetCharacters: contextBudgetCharacters)
    }

    // MARK: - Frames

    private func startFrames() async {
        guard let camera else { return }
        if !camera.isStreaming {
            try? await camera.startStreaming()
        }
        frameSubscription = camera.framePublisher.sink { [weak self] image in
            Task { @MainActor in self?.handleFrame(image) }
        }
    }

    /// Exposed for tests — the live path arrives here from the camera subscription.
    func handleFrame(_ image: UIImage) {
        guard isActive, !isPaused, !capturing else { return }
        // A reader is motionless and silent, which reads as `.idle` — the exact false negative
        // `CaptionPresenceGate` exists for. Only `.away` (disconnected or backgrounded, so there
        // are no frames anyway) justifies dropping out.
        if let presence, CaptionPresenceGate.shouldSuspend(mode: presence.mode) { return }

        let now = clock().timeIntervalSinceReferenceDate
        if let last = lastEvaluatedAt, now - last < minimumFrameInterval { return }
        lastEvaluatedAt = now

        guard let hash = PerceptualHash.dhash(image) else { return }
        guard case .pageSettled = detector.evaluate(hash: hash, now: now) else { return }
        capturePage(image, hash: hash)
    }

    private func capturePage(_ image: UIImage, hash: UInt64) {
        guard let sessionID = activeSessionID, let ocr else { return }
        capturing = true
        let capturedAt = clock()
        Task { @MainActor in
            defer { capturing = false }
            let text = await ocr(image).trimmingCharacters(in: .whitespacesAndNewlines)
            // The session can end mid-OCR — don't file a page against a session that's over.
            guard isActive, activeSessionID == sessionID else { return }
            guard !text.isEmpty else {
                // A settled view we couldn't read is not a page the reader read. Filing it would
                // put a wall or a glare-blown page into their page count and wreck the pace stats,
                // and it grounds nothing either way.
                unreadableCaptures += 1
                return
            }
            if store.appendPage(text: text, dHash: hash, at: capturedAt, to: sessionID) != nil {
                pagesThisSession += 1
            }
        }
    }
}
