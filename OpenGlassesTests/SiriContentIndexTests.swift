import XCTest
@testable import OpenGlasses

/// Plan BQ P2 — content adapters, exposure policy, diff planner, and donation
/// orchestration (mock indexer + provider override; no CoreSpotlight, no `.shared`
/// service construction).
final class SiriContentIndexTests: XCTestCase {

    // MARK: Adapters

    func testQuickNoteAdapterTitleFallbackAndStableId() {
        let note = StoredQuickNote(
            title: nil,
            content: "Remember to calibrate the flow meter before Thursday",
            timestamp: Date(timeIntervalSince1970: 1_000_000))
        let first = SiriContentAdapters.notes(quick: [note], contextual: [])
        let second = SiriContentAdapters.notes(quick: [note], contextual: [])

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].contentType, .note)
        XCTAssertTrue(first[0].title.hasPrefix("Remember to calibrate"))
        // Ids must be launch-stable (SHA-based, not String.hashValue) or every refresh
        // would churn the entire index.
        XCTAssertEqual(first[0].itemId, second[0].itemId)
    }

    func testContextualNoteAdapterCarriesTagsAndLocation() {
        let note = ContextualNote(
            id: "cn1", content: "Great flat white here", tags: ["coffee"],
            latitude: -41.3, longitude: 174.8, locationName: "Wellington",
            createdAt: Date(timeIntervalSince1970: 2_000_000))
        let records = SiriContentAdapters.notes(quick: [], contextual: [note])
        XCTAssertEqual(records[0].itemId, "cn1")
        XCTAssertTrue(records[0].keywords.contains("coffee"))
        XCTAssertTrue(records[0].keywords.contains("Wellington"))
    }

    func testMeetingSummaryAdapterFiltersByTitlePrefix() {
        let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 3_000_000))
        let raw: [[String: String]] = [
            ["title": "Meeting Summary — 7/14/26, 9:00 AM", "content": "Decided to ship BQ", "date": iso],
            ["title": "Grocery list", "content": "milk, eggs", "date": iso],
        ]
        let records = SiriContentAdapters.meetingSummaries(rawSavedNotes: raw)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].contentType, .meetingSummary)
        XCTAssertEqual(records[0].text, "Decided to ship BQ")
        XCTAssertNotNil(records[0].date)
    }

    func testSavedLocationAdapterFallsBackToCoordinates() {
        let location = StoredSavedLocation(
            label: "trailhead", latitude: -41.29, longitude: 174.77,
            address: nil, timestamp: Date(timeIntervalSince1970: 4_000_000))
        let records = SiriContentAdapters.savedLocations([location])
        XCTAssertEqual(records[0].title, "trailhead")
        XCTAssertTrue(records[0].text.contains("-41.29"))
        XCTAssertTrue(records[0].keywords.contains("trailhead"))
    }

    func testTeleprompterAndStudyAdapters() {
        let script = SavedScript(
            id: UUID(), title: "Keynote open", text: "Welcome everyone…",
            createdAt: Date(), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        let scriptRecords = SiriContentAdapters.teleprompterScripts([script])
        XCTAssertEqual(scriptRecords[0].itemId, script.id.uuidString)
        XCTAssertEqual(scriptRecords[0].title, "Keynote open")

        let deck = StudyDeck(
            id: "d1", createdAt: Date(timeIntervalSince1970: 6_000_000), source: "physics.pdf",
            summary: StudySummary(
                title: "Thermodynamics", overview: "Heat and entropy basics",
                keyPoints: ["Entropy never decreases"], docType: "pdf"),
            flashcards: [], quiz: [])
        let deckRecords = SiriContentAdapters.studyDecks([deck])
        XCTAssertEqual(deckRecords[0].title, "Thermodynamics")
        XCTAssertTrue(deckRecords[0].text.contains("Entropy never decreases"))
        XCTAssertTrue(deckRecords[0].keywords.contains("physics.pdf"))
    }

    func testConversationAdapterIsTitlesOnlyByConstruction() {
        let input = ConversationSummaryInput(
            id: "t1", title: "Trip planning", summary: "Flights and packing",
            updatedAt: Date(timeIntervalSince1970: 7_000_000))
        let records = SiriContentAdapters.conversations([input])
        XCTAssertEqual(records[0].title, "Trip planning")
        XCTAssertEqual(records[0].text, "Flights and packing")
        // The input type has no message bodies — nothing else *can* leak.
    }

    func testFieldSessionAdapterMetadataOnlyCompletedOnlyVaultGated() {
        let completed = FieldSession(
            id: "s1", vaultId: "refrigeration", assetId: "compressor-7", mode: .aiOnly,
            startedAt: Date(timeIntervalSince1970: 8_000_000),
            endedAt: Date(timeIntervalSince1970: 8_100_000),
            pausedAt: nil, resumedAt: nil, outcome: .resolved,
            startLocation: nil, endLocation: nil, escalations: [], billableSeconds: 900)
        let inProgress = FieldSession(
            id: "s2", vaultId: "refrigeration", assetId: "chiller-2", mode: .aiOnly,
            startedAt: Date(), endedAt: nil, pausedAt: nil, resumedAt: nil,
            outcome: .inProgress, startLocation: nil, endLocation: nil,
            escalations: [], billableSeconds: 0)
        let otherVault = FieldSession(
            id: "s3", vaultId: "hvac", assetId: "ahu-1", mode: .aiOnly,
            startedAt: Date(), endedAt: Date(), pausedAt: nil, resumedAt: nil,
            outcome: .resolved, startLocation: nil, endLocation: nil,
            escalations: [], billableSeconds: 100)

        let records = SiriContentAdapters.fieldSessions(
            [completed, inProgress, otherVault],
            allowedVaults: ["refrigeration"])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].itemId, "s1")
        XCTAssertTrue(records[0].title.contains("compressor-7"))
        // Metadata only: outcome + vault, nothing transcript-shaped.
        XCTAssertEqual(records[0].text, "Outcome: resolved. Vault: refrigeration.")
    }

    // MARK: Exposure policy

    func testContentTypeDefaults() {
        let config = SiriContentIndexConfig()
        XCTAssertTrue(config.isEnabled(.note))
        XCTAssertTrue(config.isEnabled(.meetingSummary))
        XCTAssertTrue(config.isEnabled(.teleprompterScript))
        XCTAssertFalse(config.isEnabled(.conversation), "privacy: opt-in")
        XCTAssertFalse(config.isEnabled(.fieldSession), "per-vault opt-in")
    }

    func testContentTypeToggles() {
        var config = SiriContentIndexConfig()
        config.disabledTypes.insert(SiriContentType.note.rawValue)
        XCTAssertFalse(config.isEnabled(.note))

        config.optInTypes.insert(SiriContentType.conversation.rawValue)
        XCTAssertTrue(config.isEnabled(.conversation))

        XCTAssertFalse(config.isEnabled(.fieldSession))
        config.fieldSessionVaults.insert("refrigeration")
        XCTAssertTrue(config.isEnabled(.fieldSession))
    }

    // MARK: Planner

    private func record(_ id: String, text: String = "body") -> IndexableRecord {
        IndexableRecord(
            contentType: .note, itemId: id, title: "T\(id)", text: text,
            keywords: [], date: Date(timeIntervalSince1970: 42))
    }

    func testPlannerInitialDonationUpsertsEverything() {
        let plan = IndexPlanner.plan(current: [record("a"), record("b")], previous: [:])
        XCTAssertEqual(plan.upserts.map(\.itemId), ["a", "b"])
        XCTAssertTrue(plan.deletions.isEmpty)
    }

    func testPlannerNoChangesYieldsEmptyPlan() {
        let records = [record("a"), record("b")]
        let plan = IndexPlanner.plan(current: records, previous: IndexPlanner.snapshot(records))
        XCTAssertTrue(plan.isEmpty)
    }

    func testPlannerDetectsEditsAndRemovals() {
        let previous = IndexPlanner.snapshot([record("a"), record("b"), record("c")])
        let plan = IndexPlanner.plan(
            current: [record("a"), record("b", text: "edited")],
            previous: previous)
        XCTAssertEqual(plan.upserts.map(\.itemId), ["b"])
        XCTAssertEqual(plan.deletions, ["note:c"])
    }

    func testPlannerDedupesById() {
        let plan = IndexPlanner.plan(
            current: [record("a", text: "first"), record("a", text: "last-wins")],
            previous: [:])
        XCTAssertEqual(plan.upserts.count, 1)
        XCTAssertEqual(plan.upserts[0].text, "last-wins")
    }

    // MARK: Service orchestration

    @MainActor
    private final class MockIndexer: SpotlightIndexing {
        var upserted: [[GlassesContentEntity]] = []
        var deleted: [[String]] = []
        var deleteAllCount = 0
        var failNext = false

        func upsert(_ entities: [GlassesContentEntity]) async throws {
            if failNext { failNext = false; throw CocoaError(.fileWriteUnknown) }
            upserted.append(entities)
        }
        func delete(ids: [String]) async throws { deleted.append(ids) }
        func deleteAll() async throws { deleteAllCount += 1 }
    }

    @MainActor
    func testRefreshDonatesThenNoOps() async {
        let (service, indexer, defaults) = makeService()
        defer { cleanUp(defaults) }
        let fixture = [record("a"), record("b")]
        SiriContentProvider.override = { fixture }
        defer { SiriContentProvider.override = nil }

        await service.refresh()
        XCTAssertEqual(indexer.upserted.count, 1)
        XCTAssertEqual(indexer.upserted[0].count, 2)

        await service.refresh()
        XCTAssertEqual(indexer.upserted.count, 1, "unchanged records must not re-donate")
    }

    @MainActor
    func testRefreshDeletesRemovedRecords() async {
        let (service, indexer, defaults) = makeService()
        defer { cleanUp(defaults) }
        var records = [record("a"), record("b")]
        SiriContentProvider.override = { records }
        defer { SiriContentProvider.override = nil }

        await service.refresh()
        records = [record("a")]
        await service.refresh()

        XCTAssertEqual(indexer.deleted, [["note:b"]])
    }

    @MainActor
    func testRefreshFailureLeavesSnapshotForRetry() async {
        let (service, indexer, defaults) = makeService()
        defer { cleanUp(defaults) }
        let fixture = [record("a")]
        SiriContentProvider.override = { fixture }
        defer { SiriContentProvider.override = nil }

        indexer.failNext = true
        await service.refresh()
        XCTAssertTrue(indexer.upserted.isEmpty)

        await service.refresh()
        XCTAssertEqual(indexer.upserted.count, 1, "failed delta must be retried next refresh")
    }

    @MainActor
    func testHipaaModeRefreshPurges() async {
        let saved = UserDefaults.standard.object(forKey: "hipaaMode")
        UserDefaults.standard.set(true, forKey: "hipaaMode")
        defer {
            if let saved = saved as? Bool {
                UserDefaults.standard.set(saved, forKey: "hipaaMode")
            } else {
                UserDefaults.standard.removeObject(forKey: "hipaaMode")
            }
        }

        let (service, indexer, defaults) = makeService()
        defer { cleanUp(defaults) }
        let fixture = [record("a")]
        SiriContentProvider.override = { fixture }
        defer { SiriContentProvider.override = nil }

        await service.refresh()
        XCTAssertEqual(indexer.deleteAllCount, 1)
        XCTAssertTrue(indexer.upserted.isEmpty)
    }

    @MainActor
    private func makeService() -> (SpotlightIndexService, MockIndexer, UserDefaults) {
        let suite = "SiriContentIndexTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let indexer = MockIndexer()
        return (SpotlightIndexService(indexer: indexer, defaults: defaults), indexer, defaults)
    }

    private func cleanUp(_ defaults: UserDefaults) {
        defaults.dictionaryRepresentation().keys.forEach(defaults.removeObject(forKey:))
    }
}
