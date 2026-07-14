import XCTest
@testable import OpenGlasses

/// Plan BQ P3 — deep-link ↔ entity mapping for onscreen-content donation.
final class SiriOnscreenContentTests: XCTestCase {

    func testEntityFromLinkParsesCompositeId() {
        let link = SiriContentLink(
            id: "meeting_summary:abc123",
            typeLabel: "Meeting Summaries",
            title: "Meeting Summary — 7/14",
            text: "Decided to ship BQ P3",
            date: Date(timeIntervalSince1970: 42))
        let entity = GlassesContentEntity(link: link)

        XCTAssertNotNil(entity)
        XCTAssertEqual(entity?.id, "meeting_summary:abc123")
        XCTAssertEqual(entity?.contentTypeRaw, "meeting_summary")
        XCTAssertEqual(entity?.title, "Meeting Summary — 7/14")
        XCTAssertEqual(entity?.text, "Decided to ship BQ P3")
        XCTAssertEqual(entity?.typeLabel, "Meeting Summaries")
    }

    func testEntityFromLinkPreservesItemIdsContainingColons() {
        let link = SiriContentLink(
            id: "note:a:b:c", typeLabel: "Notes", title: "T", text: "", date: nil)
        let entity = GlassesContentEntity(link: link)
        XCTAssertEqual(entity?.id, "note:a:b:c")
    }

    func testEntityFromLinkRejectsUnknownType() {
        let link = SiriContentLink(
            id: "face_recognition:someone", typeLabel: "?", title: "T", text: "", date: nil)
        XCTAssertNil(GlassesContentEntity(link: link))
    }

    func testEntityRecordRoundTrip() {
        let record = IndexableRecord(
            contentType: .conversation, itemId: "t1", title: "Trip planning",
            text: "Flights", keywords: ["conversation"], date: Date(timeIntervalSince1970: 7))
        let entity = GlassesContentEntity(record: record)
        XCTAssertEqual(entity.id, "conversation:t1")
        XCTAssertEqual(entity.plainText, "Trip planning\n\nFlights")
    }
}
