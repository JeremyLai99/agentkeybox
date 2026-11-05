import XCTest

@testable import AgentKeyBoxCore

#if DEBUG
  final class DevelopmentProfileTests: XCTestCase {
    private let id = UUID(uuidString: "593D6043-A276-4C12-A1C3-453DD37062BF")!

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
