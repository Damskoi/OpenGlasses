import Foundation

/// Persists reading sessions and their page captures (docs/plans/BT-reading-companion.md P1).
/// One JSON file under Application Support; directory + FileManager injectable for tests.
///
/// This is the reading companion's grounding corpus and the *only* thing the assistant is allowed
/// to answer from — see `ReadingContextBuilder`. Nothing about a book beyond what the reader has
/// looked at ever enters it, which is what makes the spoiler rule structural rather than a promise
/// in a prompt.
///
/// The store is deliberately dumb about lifecycle: it never decides which session is "current"
/// (that's the P2 service) and it derives every statistic on demand rather than storing it, so
/// stats can't drift away from the captures they describe.
@MainActor
final class ReadingSessionStore: ObservableObject {
    static let shared = ReadingSessionStore()

    /// Newest-first, matching the house convention for list-backing stores.
    @Published private(set) var sessions: [ReadingSession] = []

    private let directory: URL
    private let fileManager: FileManager
    private let duplicateHashDistance: Int

    /// Below this length, matching text means "OCR found nothing much" rather than "same page", so
    /// text-equality dedup is only trusted on a real paragraph's worth of characters.
    private static let minimumTextMatchLength = 40

    /// - Parameters:
    ///   - duplicateHashDistance: Hamming distance at/below which a capture is the same page as one
    ///     already filed. Tight by default (2 of 64): a missed duplicate merely repeats a page in
    ///     the corpus, whereas a false duplicate silently drops a page the reader did read, so the
    ///     error that costs data is the one to avoid.
    init(directory: URL? = nil, fileManager: FileManager = .default, duplicateHashDistance: Int = 2) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        self.duplicateHashDistance = max(0, duplicateHashDistance)
        load()
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ReadingSessions", isDirectory: true)
    }

    private var sessionsURL: URL { directory.appendingPathComponent("sessions.json") }

    // MARK: - Sessions

    @discardableResult
    func startSession(bookID: String, bookTitle: String, at date: Date = Date()) -> ReadingSession {
        let session = ReadingSession(bookID: bookID, bookTitle: bookTitle, startedAt: date)
        sessions.insert(session, at: 0)
        persist()
        return session
    }

    func endSession(id: String, at date: Date = Date()) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].endedAt = date
        persist()
    }

    func session(id: String) -> ReadingSession? { sessions.first { $0.id == id } }

    /// Sessions for one book, oldest-first — the order they were read in.
    func sessions(forBook bookID: String) -> [ReadingSession] {
        sessions.filter { $0.bookID == bookID }.sorted { $0.startedAt < $1.startedAt }
    }

    func deleteSession(id: String) {
        sessions.removeAll { $0.id == id }
        persist()
    }

    func deleteBook(id bookID: String) {
        sessions.removeAll { $0.bookID == bookID }
        persist()
    }

    // MARK: - Pages

    /// File a page against a session. Returns the capture, or `nil` if the session is unknown or
    /// the page is one this book already has.
    ///
    /// `pageIndex` is assigned book-scoped, so page numbering runs across sessions: picking a book
    /// back up on Tuesday continues Monday's count rather than restarting it.
    @discardableResult
    func appendPage(text: String, dHash: UInt64, at date: Date = Date(), to sessionID: String) -> PageCapture? {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
        let priorPages = pages(forBook: sessions[idx].bookID)
        guard !isDuplicate(text: text, dHash: dHash, among: priorPages) else { return nil }

        let capture = PageCapture(pageIndex: priorPages.count, text: text, capturedAt: date, dHash: dHash)
        sessions[idx].pages.append(capture)
        persist()
        return capture
    }

    /// Every page of a book in reading order, across all its sessions — the grounding corpus.
    func pages(forBook bookID: String) -> [PageCapture] {
        sessions.filter { $0.bookID == bookID }
            .flatMap(\.pages)
            .sorted { $0.pageIndex < $1.pageIndex }
    }

    /// Whether this book has already seen this page. Two signals, because either alone has a blind
    /// spot: the hash catches a re-look whose OCR came out differently, and the text catches a
    /// re-look from a new angle or distance whose hash therefore drifted.
    private func isDuplicate(text: String, dHash: UInt64, among pages: [PageCapture]) -> Bool {
        let normalized = ReadingText.normalized(text)
        let textComparable = normalized.count >= Self.minimumTextMatchLength
        return pages.contains { page in
            if PerceptualHash.hamming(page.dHash, dHash) <= duplicateHashDistance { return true }
            return textComparable && ReadingText.normalized(page.text) == normalized
        }
    }

    // MARK: - Derived stats

    /// Books this reader has sessions for, most recently read first.
    func books() -> [(id: String, title: String)] {
        var seen = Set<String>()
        return sessions
            .sorted { $0.startedAt > $1.startedAt }
            .compactMap { seen.insert($0.bookID).inserted ? (id: $0.bookID, title: $0.bookTitle) : nil }
    }

    /// Derived stats for one book. `nil` when the book has no sessions.
    func stats(forBook bookID: String) -> ReadingStats? {
        let bookSessions = sessions(forBook: bookID)
        guard let latest = bookSessions.last else { return nil }

        let pageCount = bookSessions.reduce(0) { $0 + $1.pages.count }
        let totalMinutes = bookSessions.reduce(0) { $0 + $1.durationMinutes }
        let lastReadAt = bookSessions.compactMap { $0.endedAt ?? $0.pages.last?.capturedAt }.max()

        return ReadingStats(
            bookID: bookID,
            bookTitle: latest.bookTitle,
            sessionCount: bookSessions.count,
            pageCount: pageCount,
            totalMinutes: totalMinutes,
            pagesPerMinute: totalMinutes > 0 ? Double(pageCount) / totalMinutes : 0,
            lastReadAt: lastReadAt)
    }

    // MARK: - Persistence

    /// Save suppression after a read failure on an existing file (the on-disk data may be intact —
    /// never overwrite what we couldn't read).
    private var saveBlocked = false

    private func load() {
        switch JSONStore.loadArray(ReadingSession.self, at: sessionsURL, name: "reading_sessions") {
        case .loaded(let s), .recovered(let s, _): sessions = s
        case .corrupt: sessions = []          // original preserved in StoreRecovery
        case .unreadable: saveBlocked = true
        case .absent: break
        }
    }

    private func persist() {
        guard !saveBlocked else {
            NSLog("[ReadingSessionStore] Save skipped — last load failed to read the existing file")
            return
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(sessions).write(to: sessionsURL, options: .atomic)
        } catch {
            NSLog("[ReadingSessionStore] persist failed: %@", error.localizedDescription)
        }
    }
}
