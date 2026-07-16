import Foundation

/// One page the reader actually looked at, as captured by the reading companion
/// (docs/plans/BT-reading-companion.md P1).
///
/// `pageIndex` is book-scoped capture order — "the Nth page this reader has seen of this book" —
/// **not** the printed page number, which we have no reliable way to know. `dHash` is the
/// perceptual hash of the frame the text was read from; it's what keeps a second look at a page
/// from being filed as a second page.
struct PageCapture: Codable, Equatable, Identifiable {
    let id: String
    let pageIndex: Int
    /// The raw OCR text, always kept even when the page is aligned to a reference copy — raw is
    /// what dedup compares, and keeping it makes alignment re-runnable and reversible (P4).
    let text: String
    let capturedAt: Date
    let dHash: UInt64

    /// Where this capture sits in the book's reference copy, in reference word positions —
    /// `nil` when no reference is attached or the page didn't match (P4). Optionals so P1/P2
    /// data decodes unchanged.
    let alignedStart: Int?
    let alignedWordCount: Int?
    let alignedConfidence: Double?

    init(id: String = UUID().uuidString, pageIndex: Int, text: String, capturedAt: Date, dHash: UInt64,
         alignedStart: Int? = nil, alignedWordCount: Int? = nil, alignedConfidence: Double? = nil) {
        self.id = id
        self.pageIndex = pageIndex
        self.text = text
        self.capturedAt = capturedAt
        self.dHash = dHash
        self.alignedStart = alignedStart
        self.alignedWordCount = alignedWordCount
        self.alignedConfidence = alignedConfidence
    }

    var alignedRange: Range<Int>? {
        guard let alignedStart, let alignedWordCount, alignedWordCount > 0 else { return nil }
        return alignedStart..<(alignedStart + alignedWordCount)
    }
}

/// A user-supplied canonical copy of a book (P4) — a pointer into the Plan O `DocumentStore`,
/// never a second copy of the text. If the user later forgets the document there, alignment
/// quietly stops and reading falls back to raw OCR grounding.
struct BookReference: Codable, Equatable {
    let bookID: String
    let documentId: String
    let documentName: String
    /// Reference length in words (the alignment tokenization), persisted so progress can be
    /// derived from stored alignments without loading the book text.
    let wordCount: Int
    let attachedAt: Date

    /// "I've read up to here" — the reader's assertion, in reference word positions, covering
    /// stretches read *away from the glasses* (started the app mid-book, read offline between
    /// sittings). A single high-water mark suffices: assertions are cumulative and monotonic.
    /// Always clamped to the camera-proven frontier when set, so it can only ever fill in
    /// *behind* what the camera has witnessed — never unlock text ahead of it. `nil` = the
    /// corpus is exactly what the camera saw. Optional so P4 data decodes unchanged.
    var assertedReadUpTo: Int?

    init(bookID: String, documentId: String, documentName: String, wordCount: Int,
         attachedAt: Date, assertedReadUpTo: Int? = nil) {
        self.bookID = bookID
        self.documentId = documentId
        self.documentName = documentName
        self.wordCount = wordCount
        self.attachedAt = attachedAt
        self.assertedReadUpTo = assertedReadUpTo
    }
}

/// One sitting with one book: an ordered run of page captures between "start reading" and
/// "stop reading". Sessions are the unit the reader thinks in ("where was I?"); the book is the
/// unit the grounding corpus is scoped to.
struct ReadingSession: Codable, Equatable, Identifiable {
    let id: String
    let bookID: String
    let bookTitle: String
    let startedAt: Date
    var endedAt: Date?
    var pages: [PageCapture]

    init(id: String = UUID().uuidString, bookID: String, bookTitle: String,
         startedAt: Date, endedAt: Date? = nil, pages: [PageCapture] = []) {
        self.id = id
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pages = pages
    }
}

extension ReadingSession {
    var isActive: Bool { endedAt == nil }

    /// Wall-clock minutes of reading. An open session is measured to its last page rather than to
    /// "now", so a session the reader walked away from without ending can't accrue time forever
    /// and poison the pace stats.
    var durationMinutes: Double {
        let end = endedAt ?? pages.last?.capturedAt ?? startedAt
        return max(0, end.timeIntervalSince(startedAt)) / 60
    }

    /// Pages per minute. 0 for a session with no elapsed time (a single-page session has no pace).
    var pagesPerMinute: Double {
        durationMinutes > 0 ? Double(pages.count) / durationMinutes : 0
    }
}

/// Reading stats for one book. Every field is derived from the sessions on demand — nothing here
/// is persisted, so stats can never drift out of sync with the captures they describe.
struct ReadingStats: Equatable {
    let bookID: String
    let bookTitle: String
    let sessionCount: Int
    let pageCount: Int
    let totalMinutes: Double
    let pagesPerMinute: Double
    let lastReadAt: Date?
}

/// Reading-day streaks for the P3 stats surface. Pure — calendar and "today" injected.
enum ReadingStreaks {

    /// Consecutive calendar days with at least one session, counting back from today. The streak
    /// survives until a full day is missed: reading yesterday but not yet today still counts
    /// (the reader hasn't broken anything — the day isn't over), so the answer can't discourage
    /// tonight's sitting.
    static func current(sessionDates: [Date], calendar: Calendar = .current, today: Date = Date()) -> Int {
        guard !sessionDates.isEmpty else { return 0 }
        let days = Set(sessionDates.map { calendar.startOfDay(for: $0) })
        var cursor = calendar.startOfDay(for: today)
        if !days.contains(cursor) {
            // No sitting yet today — the streak may still be alive through yesterday.
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}

/// Whitespace normalisation shared by the store's dedup and the context builder.
///
/// OCR of a printed page arrives with a line break per *printed* line, which is noise to both a
/// text comparison and a language model. Collapsing every whitespace run to a single space makes
/// the two agree on what "the same text" means.
enum ReadingText {
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
