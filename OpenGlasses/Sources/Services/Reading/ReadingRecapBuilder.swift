import Foundation

/// Spoken recaps and the study-deck source for a reading session (docs/plans/BT-reading-companion.md P2).
///
/// Everything here is a **deterministic fallback that never needs a model**: "where was I?" must answer
/// instantly when the reader picks the book back up, offline, before any LLM is warm. The end-of-session
/// recap prefers the deck summary the LLM produces (one call, two artifacts) and drops to the heuristic
/// here when generation fails — which is why these read as complete sentences rather than as a template
/// waiting to be filled in.
///
/// Same spoiler rule as the rest of the vertical: every word comes from pages the reader has seen.
///
/// Pure and headless — no store, no `Date()`, no I/O.
enum ReadingRecapBuilder {

    /// How much of the last page to read back as a reminder of where the reader stopped.
    private static let tailExcerptCharacters = 240

    /// Spoken when a session starts on a book with prior pages — "where was I?".
    /// `nil` when there's nothing read yet, so the caller can say its own first-session line.
    static func resumeRecap(stats: ReadingStats, lastPageText: String?) -> String? {
        guard stats.pageCount > 0 else { return nil }

        var out = "You're \(stats.pageCount) page\(plural(stats.pageCount)) into \(stats.bookTitle)"
        if stats.sessionCount > 1 {
            out += ", across \(stats.sessionCount) sittings"
        }
        out += "."
        if let pace = paceSentence(stats) { out += " \(pace)" }
        if let tail = excerptSentence(lastPageText, lead: "Last thing you read:") { out += " \(tail)" }
        return out
    }

    /// Spoken and saved as a note when a session ends. `overview` is the deck summary when the LLM
    /// produced one; without it this still stands on its own.
    static func sessionRecap(session: ReadingSession, overview: String?, keyPoints: [String] = []) -> String? {
        guard !session.pages.isEmpty else { return nil }

        let count = session.pages.count
        var out = "That's \(count) page\(plural(count)) of \(session.bookTitle)"
        let minutes = Int(session.durationMinutes.rounded())
        if minutes > 0 { out += " in \(minutes) minute\(plural(minutes))" }
        out += "."

        if let overview = overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty {
            out += " \(overview)"
        } else if let tail = excerptSentence(session.pages.last?.text, lead: "You finished on:") {
            // No model — fall back to where they actually stopped, which is the one thing we know.
            out += " \(tail)"
        }

        let points = keyPoints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !points.isEmpty {
            out += "\n\nWhat came up:\n" + points.map { "- \($0)" }.joined(separator: "\n")
        }
        return out
    }

    /// The text handed to deck generation. Only this session's pages — a deck over the whole book
    /// would quiz the reader on chapters they haven't reached, which is the spoiler rule in a
    /// different coat. `nil` when the session has no readable text.
    static func deckSource(session: ReadingSession) -> String? {
        let pages = session.pages
            .sorted { $0.pageIndex < $1.pageIndex }
            .compactMap { page -> String? in
                let text = ReadingText.normalized(page.text)
                return text.isEmpty ? nil : "[p\(page.pageIndex + 1)] \(text)"
            }
        return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
    }

    /// System prompt for deck generation over reading pages. `StudyContentBuilder`'s default already
    /// says "base every card on the document", but a model that recognises the book will happily
    /// reach past it — so the scope has to be stated in the terms this vertical cares about.
    static func deckSystemPrompt(bookTitle: String, maxFlashcards: Int = 12, maxQuiz: Int = 6) -> String {
        """
        You are a study assistant helping a reader retain what they just read of "\(bookTitle)". \
        The supplied text is **only the pages they read in this sitting** — not the whole book. \
        Base every card, question and summary solely on that text. Do not use anything you know \
        about this book from outside it, and never reference, hint at or foreshadow events beyond \
        the last page supplied. Return ONLY structured content with: a `summary` (title, a 1–3 \
        sentence overview of what happened in these pages, 3–5 key_points, and doc_type), up to \
        \(maxFlashcards) `flashcards` (front question/term, back answer), and up to \(maxQuiz) \
        `quiz` multiple-choice questions (prompt, 3–4 plausible options, and correct_index = the \
        0-based index of the single correct option). Make distractors plausible but clearly wrong.
        """
    }

    // MARK: - Internals

    private static func plural(_ n: Int) -> String { n == 1 ? "" : "s" }

    /// Pace only when there's enough of it to mean anything — one page in a two-minute session
    /// extrapolates to nonsense, and a spoken stat that's obviously wrong costs more trust than
    /// the stat was worth.
    private static func paceSentence(_ stats: ReadingStats) -> String? {
        guard stats.pageCount >= 3, stats.totalMinutes >= 1, stats.pagesPerMinute > 0 else { return nil }
        let minutesPerPage = 1 / stats.pagesPerMinute
        guard minutesPerPage >= 0.1, minutesPerPage < 60 else { return nil }
        let rounded = (minutesPerPage * 10).rounded() / 10
        let value = rounded < 1
            ? "\(Int((rounded * 60).rounded())) seconds"
            : "\(rounded.formatted(.number.precision(.fractionLength(0...1)))) minutes"
        return "That's about \(value) a page."
    }

    private static func excerptSentence(_ text: String?, lead: String) -> String? {
        guard let text else { return nil }
        let normalized = ReadingText.normalized(text)
        guard !normalized.isEmpty else { return nil }
        return "\(lead) \"\(tail(of: normalized, limit: tailExcerptCharacters))\""
    }

    /// The *end* of the page, not the start — the reader stopped at the bottom, so that's the line
    /// that reminds them where they are.
    private static func tail(of text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = String(text.suffix(limit))
        guard let space = cut.firstIndex(of: " ") else { return "…" + cut }
        return "…" + cut[cut.index(after: space)...]
    }
}
