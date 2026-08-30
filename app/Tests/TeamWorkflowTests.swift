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

    func testNamingConfigurationEqualityDetectsPersistedChanges() {
        let baseline = NamingConfig()
        var changed = baseline

        changed.fileTemplate = "{code}_{seq:0000}"
        XCTAssertNotEqual(changed, baseline)
        changed = baseline
        changed.folderTemplate = "{date:yyyyMMdd}"
        XCTAssertNotEqual(changed, baseline)
        changed = baseline
        changed.renameOnIngest = true
        XCTAssertNotEqual(changed, baseline)
        changed = baseline
        changed.projectCode = "JOB"
        XCTAssertNotEqual(changed, baseline)
        changed = baseline
        changed.separator = "-"
        XCTAssertNotEqual(changed, baseline)
        changed = baseline
        changed.learnedFrom = "Archive"
        XCTAssertNotEqual(changed, baseline)
        changed = baseline
        changed.consistencyAtLearn = 0.9
        XCTAssertNotEqual(changed, baseline)
    }

    @MainActor
    func testRunSummaryUsesNaturalSingularAndPluralGrammar() {
        var progress = OffloadProgress()
        progress.phase = .done
        progress.totalFiles = 1
        progress.filesVerified = 1
        progress.filesAlreadyPresent = 1

        XCTAssertEqual(
            AppState.summary(progress, destinations: 1),
            "Done — 1 file verified on 1 destination. 1 was already there and matched, so nothing was rewritten."
        )

        progress.totalFiles = 2
        progress.filesVerified = 2
        progress.filesAlreadyPresent = 2
        XCTAssertEqual(
            AppState.summary(progress, destinations: 2),
            "Done — 2 files verified on 2 destinations. 2 were already there and matched, so nothing was rewritten."
        )
    }

    func testDateFieldRequiresExactRealCalendarDate() {
        let field = IngestFormField(label: "Shoot date", kind: .date, required: true)
        XCTAssertTrue(field.isValid(answer: "2026-08-27"))
        XCTAssertFalse(field.isValid(answer: "2026-8-27"))
        XCTAssertFalse(field.isValid(answer: "2026-02-30"))
    }

    func testRunContextFreezesAnswersDefaultsDateAndOutputSettingsAtStart() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = 2026
        components.month = 8
        components.day = 27
        let start = try XCTUnwrap(components.date)
        let automatic = IngestFormField(
            label: "Shoot date", kind: .date, required: true,
            token: "shootDate", automaticValue: .today)
        let shooter = IngestFormField(
            label: "Shooter", required: true, defaultValue: "Default DP", token: "shooter")
        var config = IngestConfig()
        config.form.fields = [automatic, shooter]
        config.checksum = .sha1
        config.workflow.manifest = true
        var answers = [shooter.id: "Jordan Lee"]

        let run = IngestRunContext(config: config, answers: answers, startedAt: start)

        answers[shooter.id] = "Changed during transfer"
        config.checksum = .md5
        config.workflow.manifest = false
        config.form.fields.removeAll()

        XCTAssertEqual(run.answers[automatic.id], "2026-08-27")
        XCTAssertEqual(run.answers[shooter.id], "Jordan Lee")
        XCTAssertEqual(run.config.checksum, .sha1)
        XCTAssertTrue(run.config.workflow.manifest)
        XCTAssertEqual(run.config.form.fields.map(\.id), [automatic.id, shooter.id])
    }

    func testIngestRecordReportsTheActualManifestOutcome() {
        let destination = Destination(root: "/Volumes/WORK", label: "Work", isPrimary: true)
        var file = IngestFile(
            sourcePath: "/Volumes/CARD/A001.mov", relativePath: "A001.mov",
            destinationRelativePath: "A001.mov", size: 4)
        file.sourceHash = "abcd"
        file.destinations[destination.root] = .verified(hash: "abcd")
        var progress = OffloadProgress()
        progress.totalFiles = 1
        progress.totalBytes = 4
        progress.filesVerified = 1

        func record(_ manifest: IngestSidecar.ManifestReceipt,
                    progress: OffloadProgress) -> String {
            IngestSidecar.text(
                fields: [], answers: [:], sourceName: "CARD",
                destinations: [destination], files: [file],
                algorithm: .xxhash64, progress: progress, manifest: manifest)
        }

        XCTAssertTrue(record(.written("CARD_001.mhl"), progress: progress)
            .contains("Manifest          CARD_001.mhl (ASC MHL)"))
        XCTAssertTrue(record(.disabled, progress: progress)
            .contains("Manifest          disabled by team configuration"))

        progress.failures = ["Manifest → Work: disk full"]
        let failed = record(.notWritten("the manifest write failed"), progress: progress)
        XCTAssertTrue(failed.contains("Manifest          not written — the manifest write failed"))
        XCTAssertTrue(failed.contains("PROBLEMS\n  Manifest → Work: disk full"))
        XCTAssertFalse(failed.contains("DID NOT VERIFY"))
        XCTAssertFalse(failed.contains("manifest is alongside"))
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
        XCTAssertEqual(Set(package.form.fields.compactMap(\.token)),
                       Set(["shootDate", "shooter", "location", "project", "camera",
                            "jobNumber", "reel", "notes"]))
        XCTAssertEqual(package.team.workflows.first?.folders,
                       IngestWorkflowPreset.standard.folders)
    }

    func testFulfillmentGeneratorProducesAnImportableProfile() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-fulfillment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            repository.appendingPathComponent("fulfillment/ingest_fulfillment.py").path,
            "fulfill",
            repository.appendingPathComponent("fulfillment/example-request.json").path,
            output.path
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let profileURL = output.appendingPathComponent("Vaultline-Ingest-Team-Profile.json")
        let package = try JSONDecoder().decode(
            TeamConfigurationPackage.self, from: Data(contentsOf: profileURL)).validated()
        XCTAssertEqual(package.team.teamName, "Example Media Team")
        XCTAssertEqual(package.naming.fileTemplate, "{date:yyMMdd}_{code}_{reel}_{seq:0000}")
        XCTAssertEqual(Set(package.form.fields.compactMap(\.token)),
                       Set(["project", "shooter", "camera", "reel"]))
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

    func testEmptyParentSubpathCreatesJobDirectlyUnderSelectedDestination() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var workflow = IngestWorkflowPreset.standard
        workflow.parentSubpath = ""

        let plan = try ConfiguredJobPlan.make(
            workflow: workflow,
            selectedRoot: root,
            values: .init(fields: ["project": "Launch"], date: fixedDate))

        XCTAssertEqual(plan.parent.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(plan.jobRoot.deletingLastPathComponent().standardizedFileURL,
                       root.standardizedFileURL)
        XCTAssertNoThrow(try ConfiguredJobBuilder.create(plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.mediaRoot.path))
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

    func testBuilderRejectsExistingLinkedFolderThatEscapesSelectedDestination() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("01 Shoots"),
            withDestinationURL: outside)
        let plan = try ConfiguredJobPlan.make(
            workflow: .standard, selectedRoot: root,
            values: .init(fields: ["project": "Launch"], date: fixedDate))

        XCTAssertThrowsError(try ConfiguredJobBuilder.create(plan))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent(plan.jobName).path))
    }

    func testBuilderRejectsFileAtConfiguredFolderBeforeCreatingAnythingElse() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let values = WorkflowTemplate.Values(fields: ["project": "Launch Film"], date: fixedDate)
        let plan = try ConfiguredJobPlan.make(
            workflow: .standard, selectedRoot: root, values: values)
        try FileManager.default.createDirectory(at: plan.jobRoot, withIntermediateDirectories: true)
        // `01_Media` is an implicit ancestor of configured leaf paths such as
        // `01_Media/Camera`; it must be preflighted too.
        let occupied = plan.jobRoot.appendingPathComponent("01_Media")
        let original = Data("this is a file, not a folder".utf8)
        try original.write(to: occupied)

        XCTAssertThrowsError(try ConfiguredJobBuilder.create(plan)) { error in
            XCTAssertTrue(error.localizedDescription.contains("a file already exists"))
            XCTAssertTrue(error.localizedDescription.contains("Nothing was changed"))
        }
        XCTAssertEqual(try Data(contentsOf: occupied), original)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: plan.jobRoot.appendingPathComponent("02_Edit").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: plan.jobRoot.appendingPathComponent("03_Exports").path))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultline-team-workflow-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
