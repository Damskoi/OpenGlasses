import XCTest
@testable import OpenGlasses

/// Plan BQ P1 — harvester mapping, Config persistence round-trip, and the static-intent
/// runtime guard. UserDefaults-backed state is pinned and restored (the
/// `SiriIntentSupportTests` pattern) — no `.shared` services are exercised.
final class SiriExposureConfigTests: XCTestCase {
    private let configKey = "siriExposureConfig"
    private var savedConfigData: Data?

    override func setUp() {
        super.setUp()
        savedConfigData = UserDefaults.standard.data(forKey: configKey)
        UserDefaults.standard.removeObject(forKey: configKey)
    }

    override func tearDown() {
        if let savedConfigData {
            UserDefaults.standard.set(savedConfigData, forKey: configKey)
        } else {
            UserDefaults.standard.removeObject(forKey: configKey)
        }
        super.tearDown()
    }

    // MARK: Harvester

    func testHarvesterMapsAllFourKinds() {
        let customTool = CustomToolDefinition(
            id: "ct1", name: "garage_door", description: "Opens the garage",
            parameters: [], actionType: .urlScheme, shortcutName: nil, urlTemplate: "x://y")
        let harvested = CapabilityHarvester.harvest(
            flows: [(id: "f1", title: "Pump Inspection")],
            procedures: [(id: "p1", title: "Compressor Reset")],
            playbooks: [(id: "b1", name: "Morning Opening")],
            customTools: [customTool]
        )
        XCTAssertEqual(harvested.count, 4)
        XCTAssertEqual(harvested.map(\.kind), [.captureFlow, .procedure, .playbook, .customTool])
        XCTAssertEqual(harvested[0].id, "capture_flow:f1")
        XCTAssertEqual(harvested[1].title, "Compressor Reset")
        XCTAssertEqual(harvested[3].capabilityId, "garage_door")
    }

    func testHarvesterEmptyInputsYieldEmpty() {
        XCTAssertTrue(CapabilityHarvester.harvest().isEmpty)
    }

    // MARK: Config persistence

    func testDefaultConfigWhenUnset() {
        let config = Config.siriExposure
        XCTAssertTrue(config.disabledBuiltinActions.isEmpty)
        XCTAssertTrue(config.enabledCapabilityIds.isEmpty)
        XCTAssertTrue(config.userActions.isEmpty)
    }

    func testConfigRoundTripsThroughUserDefaults() {
        let action = SiriActionDefinition(
            displayName: "Log coffee",
            synonyms: ["coffee time"],
            binding: .prompt(text: "Log that I had a coffee"))
        var config = SiriExposureConfig(userActions: [action])
        config.disabledBuiltinActions = ["analyze_food", "broadcast_toggle"]
        config.enabledCapabilityIds = ["playbook:morning-open"]

        Config.setSiriExposure(config)
        let loaded = Config.siriExposure

        XCTAssertEqual(loaded, config)
        XCTAssertEqual(loaded.userActions.first?.binding, .prompt(text: "Log that I had a coffee"))
    }

    func testBindingCodableRoundTripAllCases() throws {
        let bindings: [SiriActionBinding] = [
            .builtin(id: "take_photo"),
            .prompt(text: "Brief me"),
            .tool(name: "teleprompter", argsJSON: #"{"action":"start"}"#),
            .capability(kind: .procedure, id: "compressor-reset"),
        ]
        for binding in bindings {
            let data = try JSONEncoder().encode(binding)
            let decoded = try JSONDecoder().decode(SiriActionBinding.self, from: data)
            XCTAssertEqual(decoded, binding)
        }
    }

    // MARK: Runtime guard (static intents)

    @MainActor
    func testRequireEnabledPassesByDefault() {
        XCTAssertNoThrow(try IntentSupport.requireEnabled("take_photo"))
    }

    @MainActor
    func testRequireEnabledThrowsWhenDisabled() {
        Config.setSiriExposure(SiriExposureConfig(disabledBuiltinActions: ["take_photo"]))
        XCTAssertThrowsError(try IntentSupport.requireEnabled("take_photo")) { error in
            guard case SiriActionError.disabled = error else {
                return XCTFail("Expected SiriActionError.disabled, got \(error)")
            }
        }
        // Other builtins stay unaffected.
        XCTAssertNoThrow(try IntentSupport.requireEnabled("read_text"))
    }
}
