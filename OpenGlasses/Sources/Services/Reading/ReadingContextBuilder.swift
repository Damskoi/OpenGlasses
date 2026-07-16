import Foundation

/// Builds the reading-session prompt block for a turn (docs/plans/BT-reading-companion.md P1).
///
/// **The spoiler rule is structural, not aspirational.** The block is assembled only from
/// `PageCapture`s the reader has actually looked at, so unread text physically cannot appear in
/// context — the prompt language below tells the model what it's looking at and forbids it from
/// reaching past that, but the guarantee comes from the corpus, not from the model's compliance.
///
/// Compression mirrors the conversation-history pass in `LLMService`: keep the recent window
/// verbatim, collapse the older prefix into per-page excerpts, and hard-cap the whole thing for
/// the local model's budget. Recency wins ties, because the reader's question is nearly always
/// about the page they're on.
///
/// Pure and headless — no store, no `Date()`, no I/O.
enum ReadingContextBuilder {

    static let spoilerRule = """
        SPOILER RULE: the pages below are everything the reader has actually seen of this book. \
        Answer only from them. Do not use anything you know about this book from outside these \
        pages, and never reveal, hint at or foreshadow anything past the last page shown — not \
        even if the reader asks you to. If the answer isn't in these pages, say it hasn't come up yet.
        """

    private static let condensedHeading = "\n\nEarlier pages (condensed):"
    private static let verbatimHeading = "\n\nMost recent pages (verbatim):"

    /// Characters held back for the "N earlier pages omitted" note so it can never push the block
    /// past the cap.
    private static let omissionNoteReserve = 96

    /// The block is worthless below this much of the current page — a spoiler rule with no evidence
    /// under it is worse than no block, since it invites the model to answer from world knowledge.
    private static let minimumPageCharacters = 200

    /// Build the turn's reading block, or `nil` when there's nothing honest to say — no pages with
    /// text yet, or a budget too small to carry the rule plus a usable slice of the current page.
    /// (Returning `nil` follows the house convention: the block vanishes entirely.)
    ///
    /// - Parameters:
    ///   - bookTitle: display name for the book.
    ///   - pages: the book's captures, any order; `pageIndex` establishes reading order.
    ///   - recentPages: how many trailing pages to include verbatim (default 3).
    ///   - budgetCharacters: hard ceiling on the returned block, roughly 4 characters per token to
    ///     match the estimator in `HistoryHygiene` (default 6000 ≈ 1.5k tokens).
    ///   - excerptCharacters: per-page ceiling in the condensed section (default 160).
    static func block(bookTitle: String,
                      pages: [PageCapture],
                      recentPages: Int = 3,
                      budgetCharacters: Int = 6000,
                      excerptCharacters: Int = 160) -> String? {

        // Pages whose OCR yielded nothing can't ground an answer. They stay in the store (a page
        // was turned — that's real, and the stats want it) but contribute nothing here.
        let ordered = pages
            .sorted { $0.pageIndex < $1.pageIndex }
            .filter { !ReadingText.normalized($0.text).isEmpty }
        guard let newest = ordered.last else { return nil }

        let header = "READING — \"\(bookTitle)\": \(ordered.count) page(s) seen so far, numbered in "
            + "the order the reader saw them (p\(newest.pageIndex + 1) is where they are now)."
        let fixed = header + "\n" + spoilerRule
        let overhead = fixed.count + condensedHeading.count + verbatimHeading.count + omissionNoteReserve
        let remaining = budgetCharacters - overhead
        guard remaining >= minimumPageCharacters else { return nil }

        // Verbatim pages get first call on the budget but are capped at two-thirds of it, so a
        // long current page can't starve the condensed history that long-range questions need.
        let verbatimCap = min(remaining, max(minimumPageCharacters, budgetCharacters * 2 / 3))
        var verbatim: [String] = []
        var verbatimUsed = 0
        for page in ordered.suffix(max(1, recentPages)).reversed() {
            let line = "[p\(page.pageIndex + 1)] \(ReadingText.normalized(page.text))"
            if verbatimUsed + line.count + 1 <= verbatimCap {
                verbatim.insert(line, at: 0)
                verbatimUsed += line.count + 1
            } else {
                // The current page always ships, cut down if that's the only way it fits.
                if verbatim.isEmpty {
                    let cut = truncate(line, to: verbatimCap - 1)
                    verbatim.append(cut)
                    verbatimUsed = cut.count + 1
                }
                break
            }
        }

        let older = ordered.dropLast(verbatim.count)
        var condensed: [String] = []
        var condensedUsed = 0
        let condensedCap = remaining - verbatimUsed
        for page in older.reversed() {
            let line = "- p\(page.pageIndex + 1): \(truncate(ReadingText.normalized(page.text), to: excerptCharacters))"
            guard condensedUsed + line.count + 1 <= condensedCap else { break }
            condensed.insert(line, at: 0)
            condensedUsed += line.count + 1
        }

        var out = fixed
        let omitted = older.count - condensed.count
        if !condensed.isEmpty {
            out += condensedHeading
            out += "\n" + condensed.joined(separator: "\n")
        }
        if omitted > 0 {
            out += "\n(\(omitted) earlier page(s) dropped to fit — say so if asked about them.)"
        }
        out += verbatimHeading + "\n" + verbatim.joined(separator: "\n")
        return out
    }

    /// Cut to `limit` characters at a word boundary where there is one, marking the cut so neither
    /// the model nor the reader mistakes a truncated page for a short one.
    ///
    /// The boundary cut is only taken when it keeps at least half the budget: on one giant
    /// unbroken token the only space in range is the one inside the "[pN] " label, and honoring
    /// it would ship a bare page number with zero content — a mid-word cut is the lesser evil.
    private static func truncate(_ text: String, to limit: Int) -> String {
        guard limit > 1, text.count > limit else { return text }
        let cut = String(text.prefix(limit - 1))
        if let space = cut.lastIndex(of: " ") {
            let atBoundary = String(cut[cut.startIndex..<space])
            if atBoundary.count >= limit / 2 { return atBoundary + "…" }
        }
        return cut + "…"
    }
}
