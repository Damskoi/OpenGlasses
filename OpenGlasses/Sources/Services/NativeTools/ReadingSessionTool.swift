import Foundation

/// `reading_session` — the reading companion's voice surface (docs/plans/BT-reading-companion.md P2).
/// Delegates to `ReadingCompanionService.shared`; the assistant answers *questions* about the book
/// from the context block that service injects, so this tool only moves the session between states.
@MainActor
struct ReadingSessionTool: NativeTool {
    let name = "reading_session"

    let description = """
    Reading companion — follow along with a physical book or e-reader and answer questions about \
    what the reader has actually read so far. Actions: start (begin a session; pass the book's \
    title as 'book'), pause (stop capturing pages for a moment), resume, end (finish the sitting — \
    speaks a recap, saves it as a note, and builds a study deck from this sitting's pages), \
    where_was_i (where the reader left off, works between sessions), status. Use for "read along \
    with me", "start reading The Hobbit", "where was I", "I'm done reading". Do NOT use this to \
    answer questions about the book's content — those are answered from the reading context \
    already in your prompt. Never reveal anything past the pages the reader has read.
    """

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["start", "pause", "resume", "end", "where_was_i", "status"],
                    "description": "what to do"
                ],
                "book": [
                    "type": "string",
                    "description": "the book's title (action=start; also scopes where_was_i to that book)"
                ]
            ],
            "required": ["action"]
        ]
    }

    private let injected: ReadingCompanionService?

    /// Tests inject a service; the registry gets the shared one. Resolved lazily rather than as a
    /// `= .shared` default argument — default arguments are evaluated outside this type's actor,
    /// which the compiler flags today and rejects outright in Swift 6.
    init(service: ReadingCompanionService? = nil) {
        self.injected = service
    }

    private var service: ReadingCompanionService { injected ?? .shared }

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String)?.lowercased() ?? "status"
        let book = (args["book"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch action {
        case "start":
            guard let book, !book.isEmpty else {
                return "Which book? Say \"start reading\" with the title."
            }
            // Resolve against the shelf so "Hobbit" continues "The Hobbit" rather than forking
            // a second corpus under a new slug.
            return await service.start(bookID: service.resolveBookID(forSpokenTitle: book), bookTitle: book)

        case "pause":
            guard service.isActive else { return "No reading session is running." }
            service.pause()
            return "Paused. Say \"resume reading\" when you're back."

        case "resume":
            guard service.isActive else { return "No reading session to resume — say \"start reading\" with the title." }
            service.resume()
            return "Following along again."

        case "end":
            return await service.end()

        case "where_was_i":
            let bookID = book.map { service.resolveBookID(forSpokenTitle: $0) }
            return service.whereWasI(bookID: bookID)
                ?? "I haven't read anything with you yet."

        // "status" is also the graceful floor for any action string the model invents — never
        // error a voice turn over an enum mismatch.
        case "status":
            fallthrough
        default:
            guard let session = service.activeSession else {
                return "No reading session is running."
            }
            let pages = service.pagesThisSession
            let state = service.isPaused ? "Paused" : "Reading"
            var line = "\(state) \(session.bookTitle) — \(pages) page\(pages == 1 ? "" : "s") this sitting."
            if service.streamInterrupted {
                line += " The camera has dropped out, so I'm not seeing pages right now — say \"resume reading\" once the glasses reconnect."
            }
            return line
        }
    }
}

/// Book identity from a spoken title. Case/punctuation-insensitive so "the hobbit", "The Hobbit"
/// and "The Hobbit!" continue one book's page count rather than starting three.
enum ReadingBookID {
    static func make(from title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let kept = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(kept))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
    }
}
