import Foundation

// MARK: - Plan BQ P2 — index diff planner (pure)
//
// Computes the minimal Spotlight mutation set from the current records and the
// last-donated snapshot (composite id → content hash). `SpotlightIndexService` is a dumb
// executor of the plan; all the logic lives here where it's exhaustively testable.

enum IndexPlanner {
    struct Plan: Equatable {
        var upserts: [IndexableRecord] = []
        var deletions: [String] = []

        var isEmpty: Bool { upserts.isEmpty && deletions.isEmpty }
    }

    /// - Parameters:
    ///   - current: records the user's config currently exposes (already filtered — a
    ///     disabled type simply contributes none, and its previously-donated ids fall out
    ///     as deletions).
    ///   - previous: last-donated snapshot, composite id → `contentHash`.
    static func plan(current: [IndexableRecord], previous: [String: String]) -> Plan {
        // Last-wins dedupe by composite id (defensive: two stores mapping to one id).
        var deduped: [String: IndexableRecord] = [:]
        for record in current { deduped[record.id] = record }

        var plan = Plan()
        for (id, record) in deduped where previous[id] != record.contentHash {
            plan.upserts.append(record)
        }
        plan.deletions = previous.keys.filter { deduped[$0] == nil }.sorted()
        plan.upserts.sort { $0.id < $1.id }
        return plan
    }

    /// The snapshot to persist after a plan is applied.
    static func snapshot(_ records: [IndexableRecord]) -> [String: String] {
        var out: [String: String] = [:]
        for record in records { out[record.id] = record.contentHash }
        return out
    }
}
