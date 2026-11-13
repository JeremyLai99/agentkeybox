import XCTest

@testable import AgentKeyBoxCore

#if DEBUG
  final class DevelopmentProfileTests: XCTestCase {
    private let id = UUID(uuidString: "593D6043-A276-4C12-A1C3-453DD37062BF")!

    func testGuardRulesStayInSelectedProfileAndExplicitOverrideWins() throws {
      let profile = DevelopmentProfile(id: UUID())
      let manager = FileManager.default
      let project = profile.file("project")
      try manager.createDirectory(at: project, withIntermediateDirectories: true)
      defer { try? manager.removeItem(at: profile.directory) }
      let ledger = GuardRuleLedger(profile: profile)
      try AgentGuard.protect(projectRoot: project, keyFileNames: ["synthetic.pem"], ledger: ledger)
      XCTAssertTrue(manager.fileExists(atPath: profile.file("guard-rules.json").path))
      XCTAssertTrue(
        GuardRuleLedger(profile: profile).rules(for: project).contains("Read(synthetic.pem)"))
      let explicit = profile.file("explicit-ledger.json")
      let override = GuardRuleLedger(fileURL: explicit, profile: profile)
      override.setRules(["Read(other.pem)"], for: project)
      XCTAssertTrue(manager.fileExists(atPath: explicit.path))
      XCTAssertFalse(ledger.rules(for: project).contains("Read(other.pem)"))
    }

    func testAppPreferencesUseIsolatedProfileEvenOutsideQABundle() {
      let profile = DevelopmentProfile(id: UUID())
      let defaults = Localization.defaults(profile: profile)
      defer { defaults.removePersistentDomain(forName: profile.preferencesDomain) }
      defaults.set("synthetic-preference", forKey: "AgentKeyBoxIsolationTest")
      XCTAssertEqual(
        defaults.persistentDomain(forName: profile.preferencesDomain)?["AgentKeyBoxIsolationTest"]
          as? String, "synthetic-preference")
      XCTAssertNotEqual(profile.preferencesDomain, "dev.agentkeybox.app")
    }

    func testQAProfileRejectsAgentRegistrationAndNormalProfileAllowsIt() throws {
      XCTAssertNoThrow(try DevelopmentProfile.requireAgentRegistrationAllowed(profile: nil))
      XCTAssertThrowsError(
        try DevelopmentProfile.requireAgentRegistrationAllowed(profile: DevelopmentProfile(id: id))
      ) { error in
        XCTAssertEqual(error as? DevelopmentProfile.RegistrationError, .isolatedProfile)
        XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
      }
    }

    func testQABundleCannotFallBackToProductionWithoutEnvironment() {
      XCTAssertThrowsError(
        try DevelopmentProfile.selectedID(
          value: nil, bundleIdentifier: "dev.agentkeybox.qa.\(id.uuidString)"))
    }

    func testQABundleRequiresItsOwnProfile() throws {
      let bundle = "dev.agentkeybox.qa.\(id.uuidString)"
      XCTAssertEqual(
        try DevelopmentProfile.selectedID(
          value: id.uuidString.lowercased(), bundleIdentifier: bundle),
        id)
      XCTAssertThrowsError(
        try DevelopmentProfile.selectedID(value: UUID().uuidString, bundleIdentifier: bundle))
      XCTAssertThrowsError(
        try DevelopmentProfile.selectedID(value: "malformed", bundleIdentifier: bundle))
      XCTAssertThrowsError(
        try DevelopmentProfile.selectedID(
          value: id.uuidString, bundleIdentifier: "dev.agentkeybox.qa.invalid"))
    }

    func testOrdinaryDevelopmentAppAndStandaloneHelpersRetainSelection() throws {
      for bundle in [nil, "dev.agentkeybox.app", "agentkeybox-mcp", "akb"] as [String?] {
        XCTAssertNil(try DevelopmentProfile.selectedID(value: nil, bundleIdentifier: bundle))
        XCTAssertEqual(
          try DevelopmentProfile.selectedID(value: id.uuidString, bundleIdentifier: bundle), id)
        XCTAssertThrowsError(
          try DevelopmentProfile.selectedID(value: "", bundleIdentifier: bundle))
      }
    }
  }
#endif
