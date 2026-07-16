import Foundation

/// Aligns a noisy OCR page capture to its position in a user-supplied canonical copy of the book
/// (docs/plans/BT-reading-companion.md P4).
///
/// The asymmetry this exploits: *locating* a capture needs only a few distinctive word runs to
/// survive the OCR, while *grounding* on a capture needs the whole page to survive. Once located,
/// the corpus entry can be upgraded to the clean canonical slice — so OCR quality stops limiting
/// answer quality and only has to be good enough to say where the reader is.
///
/// **The spoiler rule is untouched by construction**: alignment only ever runs on pages the camera
/// captured, so canonical text enters the corpus solely for pages the reader demonstrably read.
/// The index never volunteers text past the furthest aligned position.
///
/// Word-shingle voting, deterministic, no LLM, no clock:
/// - the reference is tokenized once; every `shingleSize`-word run maps to its positions
///   (runs appearing more than `maxShingleOccurrences` times are non-distinctive — "said the
///   old man" — and are dropped from the index, not the vote denominator);
/// - a capture's shingles vote for candidate start positions (`referencePosition − captureOffset`);
/// - the densest cluster of votes within `clusterTolerance` words wins; confidence is the fraction
///   of the capture's shingles that landed in that cluster.
struct BookAlignmentIndex {

    struct Match: Equatable {
        /// The capture's span in reference *word* positions.
        let wordRange: Range<Int>
        /// Fraction of the capture's shingles that voted for this position (0…1).
        let confidence: Double
        /// How far through the reference the match *ends* — the reader's position (0…1).
        let progress: Double
    }

    /// Words below which a capture can't vote meaningfully (fewer than two shingles).
    static let minimumCaptureWords = 6

    let wordCount: Int

    private let shingleSize: Int
    private let clusterTolerance: Int
    /// Original text sliced per word so grounding keeps the book's own punctuation and case.
    private let originalWords: [Substring]
    private let shingles: [String: [Int]]

    /// - Parameters:
    ///   - text: the canonical book text, as extracted from the user's copy.
    ///   - shingleSize: words per shingle (default 3 — distinctive enough to vote, short enough
    ///     to survive OCR dropping every few words).
    ///   - maxShingleOccurrences: shingles more common than this in the reference are dropped as
    ///     non-distinctive.
    ///   - clusterTolerance: how far apart (in words) two votes can be and still support the same
    ///     candidate position — absorbs OCR insertions/deletions within a page.
    init(text: String, shingleSize: Int = 3, maxShingleOccurrences: Int = 8, clusterTolerance: Int = 30) {
        self.shingleSize = max(2, shingleSize)
        self.clusterTolerance = max(1, clusterTolerance)
        self.originalWords = text.split(whereSeparator: { $0.isWhitespace })
        self.wordCount = originalWords.count

        let normalized = originalWords.map(Self.normalizeWord)
        var map: [String: [Int]] = [:]
        if normalized.count >= self.shingleSize {
            for start in 0...(normalized.count - self.shingleSize) {
                let shingle = normalized[start..<(start + self.shingleSize)].joined(separator: " ")
                map[shingle, default: []].append(start)
            }
        }
        self.shingles = map.filter { $0.value.count <= maxShingleOccurrences }
    }

    /// Locate `captureText` in the reference. `nil` when the capture is too short, matches
    /// nothing, or the best cluster is below `minimumConfidence` — an unaligned page simply
    /// stays on its raw OCR, exactly as without a reference.
    func align(captureText: String, minimumConfidence: Double = 0.2) -> Match? {
        let captureWords = captureText
            .split(whereSeparator: { $0.isWhitespace })
            .map(Self.normalizeWord)
            .filter { !$0.isEmpty }
        guard captureWords.count >= Self.minimumCaptureWords,
              captureWords.count >= shingleSize else { return nil }

        // Every (capture offset, candidate start) pair is one potential vote.
        var pairs: [(captureOffset: Int, candidateStart: Int)] = []
        let captureShingleCount = captureWords.count - shingleSize + 1
        for offset in 0..<captureShingleCount {
            let shingle = captureWords[offset..<(offset + shingleSize)].joined(separator: " ")
            for referenceStart in shingles[shingle] ?? [] {
                pairs.append((offset, referenceStart - offset))
            }
        }
        guard !pairs.isEmpty else { return nil }

        // Densest cluster of candidate starts, counting each capture shingle at most once so a
        // shingle with several reference occurrences can't vote itself into a majority.
        let sorted = pairs.sorted { $0.candidateStart < $1.candidateStart }
        var inWindow: [Int: Int] = [:]   // captureOffset → occurrences inside the window
        var distinct = 0
        var best = (count: 0, windowLow: 0)
        var lo = 0
        for hi in sorted.indices {
            let entering = sorted[hi].captureOffset
            if inWindow[entering, default: 0] == 0 { distinct += 1 }
            inWindow[entering, default: 0] += 1
            while sorted[hi].candidateStart - sorted[lo].candidateStart > clusterTolerance {
                let leaving = sorted[lo].captureOffset
                inWindow[leaving]! -= 1
                if inWindow[leaving] == 0 { distinct -= 1 }
                lo += 1
            }
            if distinct > best.count {
                best = (distinct, sorted[lo].candidateStart)
            }
        }

        let confidence = Double(best.count) / Double(captureShingleCount)
        guard confidence >= minimumConfidence else { return nil }

        // Anchor on the *modal* start inside the winning window, not its lowest vote — a stray
        // early vote (a repeated phrase at a nearby earlier site) would otherwise drag the match
        // up to `clusterTolerance` words off and misalign the canonical slice.
        var frequency: [Int: Int] = [:]
        for pair in sorted where (best.windowLow...(best.windowLow + clusterTolerance)).contains(pair.candidateStart) {
            frequency[pair.candidateStart, default: 0] += 1
        }
        let anchor = frequency.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key ?? best.windowLow

        let start = min(max(0, anchor), max(0, wordCount - 1))
        let end = min(start + captureWords.count, wordCount)
        guard start < end else { return nil }
        return Match(wordRange: start..<end,
                     confidence: confidence,
                     progress: Double(end) / Double(max(1, wordCount)))
    }

    /// Retrieve the passages most relevant to `query` from the reader's covered region — asserted
    /// stretches, captured pages, and interpolated small same-sitting holes (P4 catch-up). Whole
    /// chapters can't ride in the prompt verbatim; the current question selects which earlier
    /// passages matter.
    ///
    /// Deterministic keyword-window scoring, no embeddings, no LLM: fixed windows are scored by
    /// how many distinct content words of the query they contain; ties break toward later
    /// positions (nearer the reader's frontier, likelier relevant). `ranges` is the hard clamp —
    /// callers pass the store's covered ranges, every one of which is at or behind the camera
    /// frontier by construction, so retrieval can never surface unread text.
    func retrieve(query: String, within ranges: [Range<Int>], maxSlices: Int = 2, windowWords: Int = 120) -> [String] {
        guard maxSlices > 0 else { return [] }

        // Content words: normalized, 3+ characters — drops "who", "is", "the"-grade noise
        // without needing a stopword list.
        let terms = Set(query.split(whereSeparator: { $0.isWhitespace })
            .map(Self.normalizeWord)
            .filter { $0.count >= 3 })
        guard !terms.isEmpty else { return [] }

        let step = max(1, windowWords / 2)
        var scored: [(start: Int, end: Int, score: Int)] = []
        for range in ranges {
            let lower = min(max(0, range.lowerBound), wordCount)
            let upper = min(max(lower, range.upperBound), wordCount)
            guard lower < upper else { continue }
            var windowStart = lower
            while windowStart < upper {
                let windowEnd = min(windowStart + windowWords, upper)
                var found: Set<String> = []
                for wordIndex in windowStart..<windowEnd {
                    let normalized = Self.normalizeWord(originalWords[wordIndex])
                    if terms.contains(normalized) { found.insert(normalized) }
                }
                if !found.isEmpty { scored.append((windowStart, windowEnd, found.count)) }
                if windowEnd == upper { break }
                windowStart += step
            }
        }
        guard !scored.isEmpty else { return [] }

        // Best-first; later-in-book breaks ties. Overlapping runners-up are skipped so two
        // slices don't spend the budget saying the same thing.
        let ranked = scored.sorted { ($0.score, $0.start) > ($1.score, $1.start) }
        var picked: [(start: Int, end: Int)] = []
        for candidate in ranked where picked.count < maxSlices {
            guard !picked.contains(where: { candidate.start < $0.end && candidate.end > $0.start }) else { continue }
            picked.append((candidate.start, candidate.end))
        }
        return picked
            .sorted { $0.start < $1.start }   // reading order in the prompt
            .map { slice(wordRange: $0.start..<$0.end) }
    }

    /// Convenience for a single contiguous region `[0, upTo)`.
    func retrieve(query: String, upTo limit: Int, maxSlices: Int = 2, windowWords: Int = 120) -> [String] {
        retrieve(query: query, within: [0..<max(0, limit)], maxSlices: maxSlices, windowWords: windowWords)
    }

    /// The reference's own text for a matched range — the clean grounding that replaces the
    /// page's raw OCR. Clamped, never past the end.
    func slice(wordRange: Range<Int>) -> String {
        let lower = min(max(0, wordRange.lowerBound), wordCount)
        let upper = min(max(lower, wordRange.upperBound), wordCount)
        guard lower < upper else { return "" }
        return originalWords[lower..<upper].joined(separator: " ")
    }

    /// Matching is case/punctuation-insensitive: OCR mangles exactly those, and "Bilbo," must
    /// vote for "bilbo".
    private static func normalizeWord(_ word: Substring) -> String {
        String(word.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            .lowercased()
    }
}
