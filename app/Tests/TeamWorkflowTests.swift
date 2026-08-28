import Foundation
import XCTest
@testable import VaultlineIngest

final class TeamWorkflowTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC-ish; formatter-local assertions avoid day

    func testFreshDefaultsAreUsefulAndTokenized() throws {
        let config = IngestConfig()
        let fields = config.form.fields
        XCTAssertTrue(config.form.enabled)
        XCTAssertEqual(Set(fields.compactMap(\.token)),
                       Set(["shootDate", "shooter", "location", "project", "camera", "jobNumber", "reel", "notes"]))
        XCTAssertTrue(fields.first { $0.token == "shootDate" }?.automaticValue == .today)
        XCTAssertTrue(fields.first { $0.token == "project" }?.required == true)
        XCTAssertEqual(config.effectiveTeam.workflows.first?.mediaFolder, "01_Media/Camera")
    }

    func testDateFieldRequiresExactRealCalendarDate() {
        let field = IngestFormField(label: "Shoot date", kind: .date, required: true)
        XCTAssertTrue(field.isValid(answer: "2026-08-27"))
        XCTAssertFalse(field.isValid(answer: "2026-8-27"))
        XCTAssertFalse(field.isValid(answer: "2026-02-30"))
    }

    func testPortablePackageRoundTripsWithoutConnectionState() throws {
        let original = TeamConfigurationPackage(
            team: TeamConfiguration(teamName: "Northstar", workflows: [.standard]),
            form: IngestFormConfig(), naming: NamingConfig(), checksum: .xxhash64,
            workflow: WorkflowConfig())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TeamConfigurationPackage.self, from: data)
        XCTAssertEqual(try decoded.team.validated().teamName, "Northstar")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("nexus"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("deviceToken"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("passport"))
    }

    func testShippedExampleConfigurationDecodesAndValidates() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repository root
        let url = repository.appendingPathComponent("configuration/example-team.json")
        let package = try JSONDecoder().decode(
            TeamConfigurationPackage.self, from: Data(contentsOf: url)).validated()
        XCTAssertEqual(package.team.teamName, "Example Media Team")
    }

    func testDateAndTeamTokensRenderWithoutRetypingDate() throws {
        let values = WorkflowTemplate.Values(fields: ["jobNumber": "184", "project": "Launch Film"], date: fixedDate)
        let output = try WorkflowTemplate.render("{date:yyyyMMdd}_{jobNumber}_{project}", values: values)
        XCTAssertTrue(output.hasSuffix("_184_Launch Film"))
        XCTAssertFalse(output.contains("{"))
    }

    func testMissingConfiguredValueBlocksJobCreation() {
        XCTAssertThrowsError(try WorkflowTemplate.render(
            "{jobNumber}_{project}", values: .init(fields: ["project": "Launch"]))) {
            XCTAssertEqual($0 as? TeamConfigurationError, .unresolvedToken("jobNumber"))
        }
    }

    func testPathTraversalConfigurationIsRejected() {
        var workflow = IngestWorkflowPreset.standard
        workflow.parentSubpath = "../../Another Client"
        XCTAssertThrowsError(try workflow.validate())
    }

    func testPlanUsesFixedParentAndConfiguredMediaFolder() throws {
        let root = URL(fileURLWithPath: "/Volumes/WORK")
        let values = WorkflowTemplate.Values(fields: ["project": "Launch"], date: fixedDate)
        let plan = try ConfiguredJobPlan.make(workflow: .standard, selectedRoot: root, values: values)
        XCTAssertEqual(plan.parent, root.appendingPathComponent("01 Shoots", isDirectory: true))
        XCTAssertTrue(plan.mediaRoot.path.hasSuffix("/01_Media/Camera"))
        XCTAssertTrue(plan.projectURL?.path.hasSuffix(".prproj") == true)
    }

    func testBuilderCreatesTreeAndCopiesRealProjectTemplate() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = root.appendingPathComponent("team-template.prproj")
        try Data("real-template".utf8).write(to: template)
        var workflow = IngestWorkflowPreset.standard
        workflow.projectTemplatePath = template.path
        let values = WorkflowTemplate.Values(fields: ["project": "Launch"], date: fixedDate)
        let plan = try ConfiguredJobPlan.make(workflow: workflow, selectedRoot: root, values: values)

        let result = try ConfiguredJobBuilder.create(plan)

        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.mediaRoot.path))
        let project = try XCTUnwrap(plan.projectURL)
        XCTAssertEqual(try Data(contentsOf: project), Data("real-template".utf8))
        XCTAssertTrue(result.projectCreated)
    }

    func testPortablePackageCanCreateRealEmbeddedProjectTemplate() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data("portable-real-template".utf8)
        var workflow = IngestWorkflowPreset.standard
        workflow.projectTemplateBase64 = expected.base64EncodedString()
        let plan = try ConfiguredJobPlan.make(
            workflow: workflow, selectedRoot: root,
            values: .init(fields: ["project": "Launch"], date: fixedDate))

        let result = try ConfiguredJobBuilder.create(plan)

        XCTAssertTrue(result.projectCreated)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(plan.projectURL)), expected)
    }

    func testWorkflowRejectsTwoProjectTemplateSources() {
        var workflow = IngestWorkflowPreset.standard
        workflow.projectTemplatePath = "/tmp/template.prproj"
        workflow.projectTemplateBase64 = Data("template".utf8).base64EncodedString()
        XCTAssertThrowsError(try workflow.validate())
    }

    func testPackageRejectsWorkflowTokenMissingFromForm() {
        var workflow = IngestWorkflowPreset.standard
        workflow.jobNameTemplate = "{date:yyMMdd}_{clientCode}"
        let package = TeamConfigurationPackage(
            team: TeamConfiguration(workflows: [workflow]), form: IngestFormConfig(),
            naming: NamingConfig(), checksum: .xxhash64, workflow: WorkflowConfig())
        XCTAssertThrowsError(try package.validated())
    }

    func testPackageRejectsDuplicateFormTokens() {
        var form = IngestFormConfig()
        form.fields[0].token = "project"
        let package = TeamConfigurationPackage(
            team: TeamConfiguration(), form: form, naming: NamingConfig(),
            checksum: .xxhash64, workflow: WorkflowConfig())
        XCTAssertThrowsError(try package.validated())
    }

    func testPackageRejectsUnsafeIngestRecordFilename() {
        var form = IngestFormConfig()
        form.sidecarName = "../../outside.txt"
        let package = TeamConfigurationPackage(
            team: TeamConfiguration(), form: form, naming: NamingConfig(),
            checksum: .xxhash64, workflow: WorkflowConfig())
        XCTAssertThrowsError(try package.validated())
    }

    func testPackageRejectsInvalidChoiceConfiguration() {
        var form = IngestFormConfig()
        form.fields.append(IngestFormField(
            label: "Camera body", kind: .choice, options: ["A", "A"], token: "cameraBody"))
        let package = TeamConfigurationPackage(
            team: TeamConfiguration(), form: form, naming: NamingConfig(),
            checksum: .xxhash64, workflow: WorkflowConfig())
        XCTAssertThrowsError(try package.validated())
    }

    func testBuilderNeverInventsProjectAndNeverOverwritesTemplate() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let values = WorkflowTemplate.Values(fields: ["project": "Launch"], date: fixedDate)
        let noTemplatePlan = try ConfiguredJobPlan.make(workflow: .standard, selectedRoot: root, values: values)
        let result = try ConfiguredJobBuilder.create(noTemplatePlan)
        XCTAssertFalse(result.projectCreated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(noTemplatePlan.projectURL).path))

        let source = root.appendingPathComponent("template.prproj")
        try Data("template".utf8).write(to: source)
        var withTemplate = IngestWorkflowPreset.standard
        withTemplate.projectTemplatePath = source.path
        let collisionPlan = try ConfiguredJobPlan.make(workflow: withTemplate, selectedRoot: root, values: values)
        let collision = try XCTUnwrap(collisionPlan.projectURL)
        try Data("existing".utf8).write(to: collision)
        XCTAssertThrowsError(try ConfiguredJobBuilder.create(collisionPlan)) {
            guard case .projectTemplateCollision = $0 as? TeamConfigurationError else {
                return XCTFail("Expected collision, got \($0)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: collision), Data("existing".utf8))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultline-team-workflow-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
