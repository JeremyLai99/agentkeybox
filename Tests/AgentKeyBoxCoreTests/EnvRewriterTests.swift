import Foundation
import XCTest

@testable import AgentKeyBoxCore

final class EnvRewriterTests: XCTestCase {
  func testRemovesOnlyTheGivenKeysAndKeepsEverythingElse() throws {
    let text = """
      # Stripe
      STRIPE_SECRET_KEY=sk_test_123 # live soon
      export OPENAI_API_KEY="sk-proj-abc"
      PORT=3000
      PRIVATE_KEY="-----BEGIN KEY-----
      line two
      -----END KEY-----"
      NEXT_PUBLIC_URL=https://example.com

      """
    let result = try XCTUnwrap(
      EnvParser.removingValues(
        of: ["STRIPE_SECRET_KEY", "OPENAI_API_KEY", "PRIVATE_KEY"], from: text))
    XCTAssertEqual(result.removed, ["STRIPE_SECRET_KEY", "OPENAI_API_KEY", "PRIVATE_KEY"])
    XCTAssertFalse(result.text.contains("sk_test_123"))
    XCTAssertFalse(result.text.contains("sk-proj-abc"))
    XCTAssertFalse(result.text.contains("line two"), "a multi-line value is removed whole")
    XCTAssertTrue(result.text.hasPrefix("# Stripe\n"))
    XCTAssertTrue(result.text.contains("export OPENAI_API_KEY=\n"), "export is kept")
    XCTAssertTrue(result.text.contains("# STRIPE_SECRET_KEY is stored in AgentKeyBox."))

    let parsed = EnvParser.parse(result.text)
    XCTAssertEqual(parsed["STRIPE_SECRET_KEY"], "")
    XCTAssertEqual(parsed["PRIVATE_KEY"], "")
    XCTAssertEqual(parsed["PORT"], "3000", "settings stay")
    XCTAssertEqual(parsed["NEXT_PUBLIC_URL"], "https://example.com")
    XCTAssertTrue(result.text.hasSuffix("\n"), "the trailing newline stays")
  }

  func testEveryAssignmentOfAKeyIsEmptied() throws {
    let result = try XCTUnwrap(
      EnvParser.removingValues(of: ["TOKEN"], from: "TOKEN=old\nA=1\nTOKEN=new\n"))
    XCTAssertFalse(result.text.contains("old"))
    XCTAssertFalse(result.text.contains("new"))
    XCTAssertEqual(result.removed, ["TOKEN"])
  }

  func testFilesWithOtherLineEndingsAreLeftAlone() {
    XCTAssertNil(EnvParser.removingValues(of: ["TOKEN"], from: "TOKEN=x\r\nA=1\r\n"))
    XCTAssertNil(EnvParser.removingValues(of: ["TOKEN"], from: "TOKEN=x\u{2028}A=1"))
  }

  func testAssignmentsReportTheirLines() {
    let assignments = EnvParser.assignments(in: "A=1\nB=\"x\ny\"\nexport C=3")
    XCTAssertEqual(assignments.map(\.key), ["A", "B", "C"])
    XCTAssertEqual(assignments[1].lines, 1..<3)
    XCTAssertEqual(assignments[2].exported, true)
  }
}
