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
    let text: String
    let capturedAt: Date
    let dHash: UInt64

    init(id: String = UUID().uuidString, pageIndex: Int, text: String, capturedAt: Date, dHash: UInt64) {
        self.id = id
        self.pageIndex = pageIndex
        self.text = text
        self.capturedAt = capturedAt
        self.dHash = dHash
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
