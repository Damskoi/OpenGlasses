import AppIntents
import SwiftUI

// MARK: - Plan BQ P3 — onscreen-content donation
//
// Associating the visible content with its app entity (via `NSUserActivity.
// appEntityIdentifier`) lets Siri/Apple Intelligence resolve "this" — "summarize this",
// "what's on screen" — against the same `GlassesContentEntity` the Spotlight index donates.
// Hard-disabled under Medical Compliance Mode, like all donation.

extension GlassesContentEntity {
    /// Rebuild an entity from a deep-link payload (the composite id carries the type).
    init?(link: SiriContentLink) {
        guard let rawType = link.id.split(separator: ":").first,
              SiriContentType(rawValue: String(rawType)) != nil else { return nil }
        self.init(record: IndexableRecord(
            contentType: SiriContentType(rawValue: String(rawType))!,
            itemId: String(link.id.dropFirst(rawType.count + 1)),
            title: link.title,
            text: link.text,
            keywords: [],
            date: link.date
        ))
    }
}

private struct SiriOnscreenContentModifier: ViewModifier {
    let entity: GlassesContentEntity?

    func body(content: Content) -> some View {
        if let entity, !Config.hipaaMode {
            content.userActivity("com.openglasses.viewing-content") { activity in
                activity.title = entity.title
                activity.appEntityIdentifier = EntityIdentifier(
                    for: GlassesContentEntity.self, identifier: entity.id)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Mark this view's primary content as the thing Siri should resolve "this" to.
    func siriOnscreenContent(_ entity: GlassesContentEntity?) -> some View {
        modifier(SiriOnscreenContentModifier(entity: entity))
    }
}
