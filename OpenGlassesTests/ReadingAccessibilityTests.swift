import XCTest
import UIKit
@testable import OpenGlasses

/// Tests for ReadingProfile persistence, ReadingMode directives, and the equipment_lookup
/// OCR-token heuristic.
final class ReadingAccessibilityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "accessibilityReadingLevel")
        UserDefaults.standard.removeObject(forKey: "accessibilityReadingLanguage")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "accessibilityReadingLevel")
        UserDefaults.standard.removeObject(forKey: "accessibilityReadingLanguage")
        super.tearDown()
    }

    // MARK: - ReadingProfile

    func testReadingLevelDefaultsToAdult() {
        XCTAssertEqual(ReadingProfile.level, .adult)
    }

    func testReadingLevelPersists() {
        ReadingProfile.setLevel(.child)
        XCTAssertEqual(ReadingProfile.level, .child)
        ReadingProfile.setLevel(.professional)
        XCTAssertEqual(ReadingProfile.level, .professional)
    }

    func testPreferredLanguagePersists() {
        ReadingProfile.setPreferredLanguage("es")
        XCTAssertEqual(ReadingProfile.preferredLanguage, "es")
        XCTAssertEqual(ReadingProfile.languageName(for: "es"), "Spanish")
    }

    // MARK: - ReadingMode

    func testModeParsingIsCaseInsensitive() {
        XCTAssertEqual(ReadingMode(rawValue: "READ"), .read)
        XCTAssertEqual(ReadingMode(rawValue: "Translate"), .translate)
        XCTAssertNil(ReadingMode(rawValue: "bogus"))
    }

    func testSimplifyDirectiveReflectsLevel() {
        let directive = ReadingMode.simplify.directive(level: .child)
        XCTAssertTrue(directive.contains("SIMPLIFY"))
        XCTAssertTrue(directive.contains("6–10"), "Got: \(directive)")
    }

    func testTranslateDirectiveNamesTargetLanguage() {
        let directive = ReadingMode.translate.directive(targetLanguage: "fr")
        XCTAssertTrue(directive.contains("TRANSLATE"))
        XCTAssertTrue(directive.contains("French"), "Got: \(directive)")
    }

    func testTranslateDirectiveFallsBackToProfileLanguage() {
        ReadingProfile.setPreferredLanguage("de")
        let directive = ReadingMode.translate.directive()
        XCTAssertTrue(directive.contains("German"), "Got: \(directive)")
    }

    func testReadAndDefineDirectivesAreDistinct() {
        XCTAssertTrue(ReadingMode.read.directive().contains("READ ALOUD"))
        XCTAssertTrue(ReadingMode.define.directive().contains("under 40 words"))
    }

    // MARK: - Ask mode (grounded Q&A over captured text)

    func testAskModeParsesItsAliases() {
        XCTAssertEqual(ReadingMode(rawValue: "ask"), .ask)
        XCTAssertEqual(ReadingMode(rawValue: "question"), .ask)
        XCTAssertEqual(ReadingMode(rawValue: "answer"), .ask)
    }

    /// The abstention contract: a low-vision user can't verify the answer, so the directive must
    /// pin grounding (ONLY the captured text) and forbid guessing.
    func testAskDirectiveGroundsAndForbidsGuessing() {
        let directive = ReadingMode.ask.directive()
        XCTAssertTrue(directive.contains("ONLY the captured text"), "Got: \(directive)")
        XCTAssertTrue(directive.contains("do NOT guess"), "Got: \(directive)")
        XCTAssertTrue(directive.contains("direct answer first"), "Got: \(directive)")
    }

    // MARK: - Sharpness scorer (guidance tailoring on empty OCR)

    /// Solid-colour JPEG — no edges at all, so the Laplacian variance is ~0 (blurry).
    private func flatJPEG() -> Data {
        let size = CGSize(width: 400, height: 300)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    /// High-contrast checkerboard — dense edges, so the variance is high (sharp).
    private func checkerboardJPEG() -> Data {
        let size = CGSize(width: 400, height: 300)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            let cell = 8
            for row in 0..<(300 / cell) where true {
                for col in 0..<(400 / cell) where (row + col) % 2 == 0 {
                    ctx.fill(CGRect(x: col * cell, y: row * cell, width: cell, height: cell))
                }
            }
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    func testFlatFrameScoresBlurry() {
        XCTAssertTrue(ImageSharpness.isBlurry(flatJPEG()), "a featureless frame reads as blurry")
    }

    func testCheckerboardScoresSharp() {
        XCTAssertFalse(ImageSharpness.isBlurry(checkerboardJPEG()), "dense edges read as sharp")
        let score = ImageSharpness.score(checkerboardJPEG()) ?? 0
        XCTAssertGreaterThan(score, ImageSharpness.blurThreshold)
    }

    func testUndecodableFrameIsNeverCalledBlurry() {
        // No evidence → no blur claim; the caller falls back to the generic guidance.
        XCTAssertNil(ImageSharpness.score(Data([0xDE, 0xAD])))
        XCTAssertFalse(ImageSharpness.isBlurry(Data([0xDE, 0xAD])))
    }

    // MARK: - equipment_lookup OCR token heuristic

    @MainActor
    func testCandidateTokensExtractsCodesAndModels() {
        let tool = EquipmentLookupTool()
        let tokens = tool.candidateTokens(from: "DAIKIN\nMODEL RXS24\nERROR E5\n!!! 12")
        XCTAssertTrue(tokens.contains("DAIKIN"))
        XCTAssertTrue(tokens.contains("RXS24"))
        XCTAssertTrue(tokens.contains("E5"))
        XCTAssertTrue(tokens.contains("12"))
    }

    @MainActor
    func testCandidateTokensDropsNoiseAndDuplicates() {
        let tool = EquipmentLookupTool()
        let tokens = tool.candidateTokens(from: "E5 e5 a thisisaverylongtokenover14chars ##")
        XCTAssertEqual(tokens.filter { $0.uppercased() == "E5" }.count, 1) // de-duped case-insensitively
        XCTAssertFalse(tokens.contains("a"))  // too short
        XCTAssertFalse(tokens.contains { $0.count > 14 })
    }
}
