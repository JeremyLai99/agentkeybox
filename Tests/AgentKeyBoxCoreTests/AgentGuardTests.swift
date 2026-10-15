import Foundation
import XCTest

@testable import AgentKeyBoxCore

final class AgentGuardTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    Localization.setOverride(.english)
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "akb-guard-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    Localization.setOverride(nil)
    try? FileManager.default.removeItem(at: root)
  }

  private func settings(at directory: URL) throws -> [String: Any] {
    let data = try Data(
      contentsOf: directory.appendingPathComponent(".claude/settings.local.json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testDenyRulesCoverEnvFilesAndKeyFilesButNotTemplates() {
    let rules = AgentGuard.claudeDenyRules(keyFileNames: ["AuthKey_ABC123DEF4.p8", "firebase.json"])
    XCTAssertEqual(Array(rules.prefix(2)), ["Read(.env)", "Read(.env.*)"])
    XCTAssertTrue(rules.contains("Read(!.env.example)"))
    XCTAssertTrue(rules.contains("Read(AuthKey_ABC123DEF4.p8)"))
    XCTAssertTrue(rules.contains("Read(firebase.json)"))
  }

  func testDenyRulesMergeIntoExistingSettingsOnce() throws {
    let directory = root.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try #"{"model":"opus","permissions":{"allow":["Bash(npm test)"],"deny":["Read(./secrets/**)"]}}"#
      .write(to: directory.appendingPathComponent("settings.local.json"), atomically: true, encoding: .utf8)

    let rules = AgentGuard.claudeDenyRules(keyFileNames: ["server.pem"])
    try AgentGuard.addClaudeDenyRules(rules, root: root)
    try AgentGuard.addClaudeDenyRules(rules, root: root)

    let merged = try settings(at: root)
    XCTAssertEqual(merged["model"] as? String, "opus", "other settings are kept")
    let permissions = try XCTUnwrap(merged["permissions"] as? [String: Any])
    XCTAssertEqual(permissions["allow"] as? [String], ["Bash(npm test)"])
    let deny = try XCTUnwrap(permissions["deny"] as? [String])
    XCTAssertEqual(deny.filter { $0 == "Read(.env)" }.count, 1, "running twice adds nothing")
    XCTAssertTrue(deny.contains("Read(./secrets/**)"))
    XCTAssertTrue(deny.contains("Read(server.pem)"))
    let firstNegation = try XCTUnwrap(deny.firstIndex { $0.hasPrefix("Read(!") })
    XCTAssertGreaterThan(
      firstNegation, try XCTUnwrap(deny.firstIndex(of: "Read(.env.*)")),
      "negations must follow the rules they carve out of")
  }

  func testBrokenSettingsFileIsLeftAlone() throws {
    let directory = root.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("settings.local.json")
    try "{ not json".write(to: file, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try AgentGuard.addClaudeDenyRules(["Read(.env)"], root: root))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{ not json")
  }

  func testInstructionsAreAddedOnceAndOtherTextIsKept() throws {
    let file = root.appendingPathComponent("AGENTS.md")
    try "# My project\n\nUse pnpm.\n".write(to: file, atomically: true, encoding: .utf8)
    try AgentGuard.writeInstructions(to: file)
    try AgentGuard.writeInstructions(to: file)
    let text = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(text.hasPrefix("# My project\n\nUse pnpm.\n"))
    XCTAssertEqual(text.components(separatedBy: "<!-- agentkeybox:start -->").count, 2)
    XCTAssertTrue(text.contains("Do not open, print, copy, or search `.env` files"))
  }

  func testProtectWritesSettingsAtTheRepositoryRootAndNotesInTheProject() throws {
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let project = root.appendingPathComponent("apps/web")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

    try AgentGuard.protect(projectRoot: project, keyFileNames: ["AuthKey_ABC123DEF4.p8"])

    let deny = try XCTUnwrap(
      (try settings(at: root)["permissions"] as? [String: Any])?["deny"] as? [String])
    XCTAssertTrue(deny.contains("Read(AuthKey_ABC123DEF4.p8)"))
    for name in ["AGENTS.md", "CLAUDE.md"] {
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: project.appendingPathComponent(name).path), name)
    }
  }
}
