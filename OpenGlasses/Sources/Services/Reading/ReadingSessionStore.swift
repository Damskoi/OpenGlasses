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

    /// Captures rejected as duplicates. In-memory diagnostic (review finding: a hash-collision
    /// false duplicate silently drops a page the reader did read — this is the counter that makes
    /// that visible on the P3 device pass, alongside `unreadableCaptures` on the service).
    private(set) var dedupDropCount = 0

    /// Below this length, matching text means "OCR found nothing much" rather than "same page", so
    /// text-equality dedup is only trusted on a real paragraph's worth of characters.
    private static let minimumTextMatchLength = 40

    /// Hash-only dedup applies only to the last N pages. A re-look is at the current spread or a
    /// page just read; letting a bare hash match reach the whole book lets a 9×8 dhash collision
    /// (two dense prose pages share margins and column structure) silently drop a genuinely new
    /// page. Older pages can still dedup, but only with the text corroborating.
    private static let hashDedupWindow = 8

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
        persistNow()
        return session
    }

    func endSession(id: String, at date: Date = Date()) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].endedAt = date
        persistNow()
    }

    func session(id: String) -> ReadingSession? { sessions.first { $0.id == id } }

    /// Sessions for one book, oldest-first — the order they were read in.
    func sessions(forBook bookID: String) -> [ReadingSession] {
        sessions.filter { $0.bookID == bookID }.sorted { $0.startedAt < $1.startedAt }
    }

    func deleteSession(id: String) {
        sessions.removeAll { $0.id == id }
        persistNow()
    }

    func deleteBook(id bookID: String) {
        sessions.removeAll { $0.bookID == bookID }
        persistNow()
    }

    // MARK: - Pages

    /// File a page against a session. Returns the capture, or `nil` if the session is unknown or
    /// the page is one this book already has.
    ///
    /// `pageIndex` is assigned book-scoped, so page numbering runs across sessions: picking a book
    /// back up on Tuesday continues Monday's count rather than restarting it. It is max+1, not
    /// count: after `deleteSession` removes a non-terminal session, count would collide with the
    /// surviving higher indices and the context block would carry two pages with the same number.
    @discardableResult
    func appendPage(text: String, dHash: UInt64, at date: Date = Date(), to sessionID: String) -> PageCapture? {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
        let bookID = sessions[idx].bookID
        // Unsorted on purpose — this path needs only a max and membership, and it runs per capture.
        let priorPages = sessions.filter { $0.bookID == bookID }.flatMap(\.pages)
        guard !isDuplicate(text: text, dHash: dHash, among: priorPages) else {
            dedupDropCount += 1
            return nil
        }

        let nextIndex = (priorPages.map(\.pageIndex).max() ?? -1) + 1
        let capture = PageCapture(pageIndex: nextIndex, text: text, capturedAt: date, dHash: dHash)
        sessions[idx].pages.append(capture)
        scheduleCheckpoint()
        return capture
    }

    /// Every page of a book in reading order, across all its sessions — the grounding corpus.
    /// `capturedAt` breaks pageIndex ties (possible in data written before max+1 indexing), since
    /// Swift's sort is not guaranteed stable.
    func pages(forBook bookID: String) -> [PageCapture] {
        sessions.filter { $0.bookID == bookID }
            .flatMap(\.pages)
            .sorted { $0.pageIndex != $1.pageIndex ? $0.pageIndex < $1.pageIndex : $0.capturedAt < $1.capturedAt }
    }

    /// Whether this book has already seen this page. Two signals, because either alone has a blind
    /// spot: the hash catches a re-look whose OCR came out differently, and the text catches a
    /// re-look from a new angle or distance whose hash therefore drifted.
    ///
    /// The hash signal is trusted alone only inside `hashDedupWindow` (a re-look is at recent
    /// pages); against the whole book a bare 9×8-dhash match is as likely a layout collision
    /// between two dense prose pages as a real re-look, and acting on it silently drops a page.
    private func isDuplicate(text: String, dHash: UInt64, among pages: [PageCapture]) -> Bool {
        let normalized = ReadingText.normalized(text)
        let textComparable = normalized.count >= Self.minimumTextMatchLength
        let hashWindowFloor = (pages.map(\.pageIndex).max() ?? -1) - Self.hashDedupWindow + 1
        return pages.contains { page in
            if page.pageIndex >= hashWindowFloor,
               PerceptualHash.hamming(page.dHash, dHash) <= duplicateHashDistance { return true }
            guard textComparable else { return false }
            // Cheap pre-filter before normalizing the stored page: normalization only collapses
            // whitespace, so texts whose raw lengths differ wildly can't normalize equal.
            guard abs(page.text.count - text.count) <= max(page.text.count, text.count) / 2 else { return false }
            return ReadingText.normalized(page.text) == normalized
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

    /// Every persist rewrites the whole corpus (all books, all pages of OCR text), so a write per
    /// page turn is the store's dominant cost and it grows with the library. Page appends therefore
    /// coalesce into a checkpoint at most this often; session lifecycle events (start/end/delete)
    /// persist immediately and cancel any pending checkpoint. Crash window: at most this many
    /// seconds of one live session's pages. `0` persists synchronously (tests).
    var checkpointInterval: TimeInterval = 60
    private var checkpointTask: Task<Void, Never>?

    private func load() {
        switch JSONStore.loadArray(ReadingSession.self, at: sessionsURL, name: "reading_sessions") {
        case .loaded(let s), .recovered(let s, _): sessions = s
        case .corrupt: sessions = []          // original preserved in StoreRecovery
        case .unreadable: saveBlocked = true
        case .absent: break
        }
    }

    private func scheduleCheckpoint() {
        guard checkpointInterval > 0 else { return persistNow() }
        guard checkpointTask == nil else { return }   // one pending checkpoint is enough
        let interval = checkpointInterval
        checkpointTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.checkpointTask = nil
            self.persist()
        }
    }

    /// Immediate persist for lifecycle events; supersedes any pending checkpoint.
    private func persistNow() {
        checkpointTask?.cancel()
        checkpointTask = nil
        persist()
    }

    private func persist() {
        guard !saveBlocked else {
            NSLog("[ReadingSessionStore] Save skipped — last load failed to read the existing file")
            return
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(sessions).write(to: sessionsURL, options: .atomic)
            protectIfNeeded(sessionsURL)
        } catch {
            NSLog("[ReadingSessionStore] persist failed: %@", error.localizedDescription)
        }
    }

    /// Camera-derived text follows the same at-rest posture as camera-derived video
    /// (`HIPAAComplianceService.protectFile`): complete file protection + no iCloud backup when
    /// compliance mode is on. New sessions can't start under `hipaaMode` (the tool is in
    /// `hipaaDisabledTools` and the service guards), so this covers data captured before the
    /// mode was enabled.
    private func protectIfNeeded(_ url: URL) {
        guard Config.hipaaMode else { return }
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(resourceValues)
    }
}
