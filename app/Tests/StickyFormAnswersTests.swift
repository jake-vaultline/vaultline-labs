import Foundation
import XCTest
@testable import VaultlineIngest

final class StickyFormAnswersTests: XCTestCase {
    func testRestoresOnlyValidStickyNonAutomaticAnswersForSameTeamForm() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let sticky = IngestFormField(label: "Shooter", required: true, sticky: true, token: "shooter")
        let nonSticky = IngestFormField(label: "Card", sticky: false, token: "reel")
        let automatic = IngestFormField(
            label: "Date", kind: .date, sticky: true, token: "shootDate", automaticValue: .today)
        var config = IngestConfig()
        config.team = TeamConfiguration(teamName: "Field Team")
        config.form.fields = [sticky, nonSticky, automatic]

        StickyFormAnswers.save([
            sticky.id: "Jordan Lee",
            nonSticky.id: "A001",
            automatic.id: "2026-08-27"
        ], config: config, defaults: defaults)

        XCTAssertEqual(
            StickyFormAnswers.load(config: config, defaults: defaults),
            [sticky.id: "Jordan Lee"])
    }

    func testDifferentTeamOrFormCannotSeePreviousTeamAnswers() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let field = IngestFormField(label: "Shooter", sticky: true, token: "shooter")
        var first = IngestConfig()
        first.team = TeamConfiguration(teamName: "Team One")
        first.form.fields = [field]
        StickyFormAnswers.save([field.id: "Jordan Lee"], config: first, defaults: defaults)

        var otherTeam = first
        otherTeam.team = TeamConfiguration(teamName: "Team Two")
        XCTAssertTrue(StickyFormAnswers.load(config: otherTeam, defaults: defaults).isEmpty)

        var changedForm = first
        changedForm.form.fields[0].label = "Camera operator"
        XCTAssertTrue(StickyFormAnswers.load(config: changedForm, defaults: defaults).isEmpty)
    }

    func testEmptyAndInvalidStickyAnswersAreNotRestored() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let choice = IngestFormField(
            label: "Camera", kind: .choice, options: ["FX6"], sticky: true, token: "camera")
        let empty = IngestFormField(label: "Location", sticky: true, token: "location")
        var config = IngestConfig()
        config.form.fields = [choice, empty]

        StickyFormAnswers.save(
            [choice.id: "Not configured", empty.id: "   "],
            config: config, defaults: defaults)

        XCTAssertTrue(StickyFormAnswers.load(config: config, defaults: defaults).isEmpty)
    }

    private var defaultsSuite: String { "StickyFormAnswersTests.\(name)" }

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        return defaults
    }
}
