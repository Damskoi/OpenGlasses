import Foundation

/// Why the uncertainty gate decided a local answer needs a web-grounded re-ask (Plan BI).
enum UncertaintyReason: Equatable {
    /// The answer itself hedged epistemically ("I'm not sure", "as of my last update", …).
    case hedged
    /// The *question* asked for volatile data ("today", "latest", "who won", …) — fires even on
    /// a confident answer, because a confident stale answer is the worst case.
    case freshnessRequested
}

struct UncertaintyVerdict: Equatable {
    let shouldSearch: Bool
    let reason: UncertaintyReason?

    static let confident = UncertaintyVerdict(shouldSearch: false, reason: nil)
}

/// Pure uncertainty gate for local-backend answers (Plan BI). The two local backends (MLX,
/// Apple Foundation) can't reach `web_search` through a tool loop, so a low-confidence or
/// freshness-sensitive completion gets detected here and transparently re-asked with search
/// grounding by `UncertaintyReask`. Cloud backends tool-call `web_search` themselves and never
/// consult this.
enum UncertaintyDetector {

    static func assess(question: String, answer: String) -> UncertaintyVerdict {
        // The web can never answer a question about the user's own data — a re-ask there
        // produces the worst possible reply ("Checked the web — I don't have access to your
        // personal calendar", live-traced). Personal-data questions are the tools' job.
        if isPersonalDataQuestion(normalize(question)) {
            return .confident
        }
        // Freshness wins the reported reason when both signals trip.
        if asksForVolatileData(normalize(question)) {
            return UncertaintyVerdict(shouldSearch: true, reason: .freshnessRequested)
        }
        if hedges(normalize(answer)) {
            return UncertaintyVerdict(shouldSearch: true, reason: .hedged)
        }
        return .confident
    }

    /// True when the question is about the user's own on-device data — calendar, reminders,
    /// alarms, health, battery — which no web search can see.
    static func isPersonalDataQuestion(_ question: String) -> Bool {
        personalDataPatterns.contains { pattern in
            question.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static let personalDataPatterns: [String] = [
        #"\bmy (calendar|schedule|agenda|appointments?|meetings?|events?)\b"#,
        #"\b(in|on) the calendar\b"#,
        #"\bmy (reminders?|alarms?|timers?)\b"#,
        #"\bmy (steps?|step count|heart rate|workouts?)\b"#,
        #"\bmy (battery|phone|device)\b"#,
        #"\bam i free\b"#,
    ]

    // MARK: - Signals

    /// Curated epistemic hedges, anchored to first-person knowledge claims — deliberately NOT a
    /// bare `contains("not sure")`, which would fire on "not sure if you'd like…" politeness.
    private static let hedgePhrases: [String] = [
        "i'm not sure", "i am not sure",
        "i'm not certain", "i am not certain",
        "i don't know", "i do not know",
        "i don't have access", "i do not have access",
        "i don't have information", "i do not have information",
        "i don't have real-time", "i do not have real-time",
        "i don't have current", "i do not have current",
        "i don't have up-to-date", "i do not have up-to-date",
        "as of my last update", "as of my knowledge cutoff", "as of my last training",
        "my training data", "my knowledge cutoff",
        "i cannot browse", "i can't browse",
        "i cannot access the internet", "i can't access the internet",
        "i'm unable to access", "i am unable to access",
        "i cannot look that up", "i can't look that up",
    ]

    /// Volatile-data markers in the question, matched on word boundaries so "score" doesn't fire
    /// inside "underscore" and "current" doesn't need to enumerate "currently".
    private static let freshnessPatterns: [String] = [
        #"\btoday\b"#, #"\btonight\b"#, #"\bright now\b"#,
        #"\blatest\b"#, #"\bcurrent(ly)?\b"#,
        #"\bthis week\b"#, #"\bthis morning\b"#, #"\bthis month\b"#,
        #"\bwho won\b"#, #"\bwho is winning\b"#,
        #"\bscores?\b"#, #"\bprice of\b"#, #"\bhow much is\b"#, #"\bhow much does\b"#,
        #"\bstock price\b"#, #"\bexchange rate\b"#,
        #"\bnews\b"#, #"\bheadlines\b"#,
    ]

    private static func hedges(_ answer: String) -> Bool {
        hedgePhrases.contains(where: answer.contains)
    }

    private static func asksForVolatileData(_ question: String) -> Bool {
        freshnessPatterns.contains { pattern in
            question.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Lowercase, straighten curly apostrophes, collapse whitespace.
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
