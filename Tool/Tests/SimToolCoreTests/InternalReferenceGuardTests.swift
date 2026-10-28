import Foundation
import XCTest

/// `Scripts/check-no-internal-refs.sh` keeps the organization that develops
/// SimTool out of the published tree. Its list of terms lives outside the
/// repository (`SIMTOOL_INTERNAL_DENYLIST`), so these tests feed it a made-up
/// one; the strings it must catch are put together at run time, or the
/// repository scan would catch this file.
final class InternalReferenceGuardTests: XCTestCase {
    private var root: URL!

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SimToolCoreTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // Tool/
        .deletingLastPathComponent()  // repository root

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("InternalReferenceGuardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Outcome {
        var status: Int32
        var output: String
    }

    private func script() throws -> URL {
        let script = Self.repositoryRoot.appendingPathComponent("Scripts/check-no-internal-refs.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("no \(script.path) (building outside a checkout)")
        }
        return script
    }

    /// Runs the guard under /bin/bash — the macOS 3.2 one, which is what it must run on.
    private func check(_ argument: String, environment: [String: String] = [:], input: String? = nil, inheriting: Bool = false) throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [try script().path, argument]
        var base = ProcessInfo.processInfo.environment
        if !inheriting {
            for key in ["SIMTOOL_INTERNAL_DENYLIST", "SIMTOOL_GITHUB_OWNER", "SIMTOOL_GITHUB_REPO", "SIMTOOL_TAP_OWNER", "SIMTOOL_TAP_REPO"] {
                base[key] = nil
            }
        }
        process.environment = base.merging(environment) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data((input ?? "").utf8))
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Outcome(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    private func write(_ text: String, to path: String) throws {
        let file = root.appendingPathComponent("tree/\(path)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func denylist(_ lines: String) throws -> String {
        let file = root.appendingPathComponent("denylist")
        try Data(lines.utf8).write(to: file)
        return file.path
    }

    private var tree: String { root.appendingPathComponent("tree").path }

    // With the team's denylist in the environment this is the real check;
    // without it, only the generic one runs, and the script says so.
    func testTheRepositoryNamesNothingInternal() throws {
        let outcome = try check(Self.repositoryRoot.path, inheriting: true)
        XCTAssertEqual(outcome.status, 0, outcome.output)
    }

    func testADenylistedTermIsFoundEverywhereButInTheRepositorysCoordinates() throws {
        try write("brew tap zorblax/simtool\nhttps://github.com/Zorblax/SimTool.git\nbrew tap zorblax/homebrew-simtool\n", to: "README.md")
        try write("Measured on the Zorblax app.\n", to: "Sources/Notes.swift")
        try write("see github.com/zorblax/SimTool, made by zorblax\n", to: "docs/both.md")
        try write("zorblax\n", to: ".build/cache.txt")
        try write("nothing here\n", to: "docs/zorblax-plan.md")
        let terms = try denylist("# the organization\n\nzorblax\n")

        let outcome = try check(tree, environment: ["SIMTOOL_INTERNAL_DENYLIST": terms, "SIMTOOL_GITHUB_OWNER": "zorblax"])

        XCTAssertEqual(outcome.status, 1, outcome.output)
        XCTAssertTrue(outcome.output.contains("Sources/Notes.swift:1:"), outcome.output)
        XCTAssertTrue(outcome.output.contains("docs/both.md:1:"), "a coordinate does not excuse the rest of its line: \(outcome.output)")
        XCTAssertTrue(outcome.output.contains("file names:"), "a file's name is published too: \(outcome.output)")
        XCTAssertFalse(outcome.output.contains("README.md"), "the repository's own coordinates are allowed: \(outcome.output)")
        XCTAssertFalse(outcome.output.contains("cache.txt"), "build directories are not the tree: \(outcome.output)")
    }

    func testIssueKeysHomeDirectoriesAndEmailsAreFoundWithoutADenylist() throws {
        let key = ["PROJ", "4321"].joined(separator: "-")
        let home = "/Users/" + "jdoe"
        let email = ["jane.doe", "corp.io"].joined(separator: "@")
        try write("fixes \(key)\nbuilt in \(home)/src\nask \(email)\n", to: "found.md")
        try write("E0D12083-7907 SHA-256 ISO-8601\n/Users/x/src /Users/me/App\ndev@example.com git@github.com icon@2x.png\n", to: "fine.md")

        let outcome = try check(tree)

        XCTAssertEqual(outcome.status, 1, outcome.output)
        XCTAssertTrue(outcome.output.contains("SIMTOOL_INTERNAL_DENYLIST is not set"), outcome.output)
        XCTAssertTrue(outcome.output.contains("found.md:1:\(key)  [issue key]"), outcome.output)
        XCTAssertTrue(outcome.output.contains("found.md:2:\(home)  [home directory]"), outcome.output)
        XCTAssertTrue(outcome.output.contains("found.md:3:\(email)  [email]"), outcome.output)
        XCTAssertFalse(outcome.output.contains("fine.md"), "UUID pieces, standards, placeholders and example addresses are fine: \(outcome.output)")
    }

    func testStandardInputIsCheckedTooForCommitMetadata() throws {
        let terms = try denylist("zorblax\n")
        let leaking = try check("-", environment: ["SIMTOOL_INTERNAL_DENYLIST": terms], input: "Jane Doe jane@zorblax.example\nAdd the Zorblax login\n")
        XCTAssertEqual(leaking.status, 1, leaking.output)
        XCTAssertTrue(leaking.output.contains("stdin:2:"), leaking.output)

        let noreply = ["1+jdoe", "users.noreply.github.com"].joined(separator: "@")
        let person = try check("-", environment: ["SIMTOOL_INTERNAL_DENYLIST": terms], input: "Jane Doe \(noreply)\nInitial commit\n")
        XCTAssertEqual(person.status, 1, "a person's address is still a person's address: \(person.output)")

        let anonymous = try check("-", environment: ["SIMTOOL_INTERNAL_DENYLIST": terms], input: "Initial commit\n")
        XCTAssertEqual(anonymous.status, 0, anonymous.output)
    }

    func testADenylistThatCannotBeReadStopsTheCheck() throws {
        let missing = try check(tree, environment: ["SIMTOOL_INTERNAL_DENYLIST": root.appendingPathComponent("missing").path])
        XCTAssertEqual(missing.status, 2, missing.output)

        let broken = try check(tree, environment: ["SIMTOOL_INTERNAL_DENYLIST": try denylist("zorblax(\n")])
        XCTAssertEqual(broken.status, 2, "a pattern grep cannot read must not match nothing quietly: \(broken.output)")
    }
}
