import Foundation
import XCTest

@testable import AgentKeyBoxCore

#if os(macOS)
  import LocalAuthentication
#endif

final class SessionRevocationTests: XCTestCase {
  private func request(_ credential: String = "synthetic-key") -> AgentRequest {
    AgentRequest(
      agentID: "fixture", agentDisplayName: "Fixture", projectPath: "/tmp/fixture",
      credentialIdentifier: credential, executablePath: "/usr/bin/true", sessionID: "fixture")
  }

  func testRevocationDuringAuthenticationPreventsGrantAndFreshApprovalSucceeds() async {
    let engine = ApprovalEngine()
    let request = request()
    let beforeAuthentication = await engine.sessionGeneration(for: request)
    await engine.revokeAllSessions()
    let staleGranted = await engine.grantSession(
      for: request, authentication: nil, generation: beforeAuthentication)
    XCTAssertFalse(staleGranted)
    let staleApproval = await engine.sessionApproval(for: request)
    XCTAssertNil(staleApproval)
    let count = await engine.activeSessionCount()
    XCTAssertEqual(count, 0)

    let freshGeneration = await engine.sessionGeneration(for: request)
    let freshGranted = await engine.grantSession(
      for: request, authentication: nil, generation: freshGeneration)
    XCTAssertTrue(freshGranted)
    let freshApproval = await engine.sessionApproval(for: request)
    XCTAssertNotNil(freshApproval)
  }

  func testCredentialRevocationRemovesEveryScopeAndRejectsPendingGrantOnlyForThatKey() async {
    let engine = ApprovalEngine()
    let first = request()
    var otherScope = first
    otherScope.arguments = ["synthetic-argument"]
    otherScope.projectPath = "/tmp/other-fixture"
    let second = request("another-synthetic-key")
    let firstGeneration = await engine.sessionGeneration(for: first)
    let secondGeneration = await engine.sessionGeneration(for: second)
    for request in [first, otherScope, second] {
      await engine.grantSession(
        for: request, authentication: nil,
        generation: await engine.sessionGeneration(for: request))
    }

    await engine.revokeSessions(for: first.credentialIdentifier)
    for request in [first, otherScope] {
      let approval = await engine.sessionApproval(for: request)
      XCTAssertNil(approval)
      let granted = await engine.grantSession(
        for: request, authentication: nil, generation: firstGeneration)
      XCTAssertFalse(granted)
    }
    let unaffected = await engine.sessionApproval(for: second)
    XCTAssertNotNil(unaffected)
    let unaffectedPending = await engine.grantSession(
      for: second, authentication: nil, generation: secondGeneration)
    XCTAssertTrue(unaffectedPending)
    let count = await engine.activeSessionCount()
    XCTAssertEqual(count, 1)
  }

  func testGenerationCannotBeUsedForAnotherCredentialOrAfterGlobalReset() async {
    let engine = ApprovalEngine()
    let first = request()
    let generation = await engine.sessionGeneration(for: first)
    let wrongKey = await engine.grantSession(
      for: request("other"), authentication: nil, generation: generation)
    XCTAssertFalse(wrongKey)
    await engine.revokeSessions(for: first.credentialIdentifier)
    let credentialGeneration = await engine.sessionGeneration(for: first)
    await engine.revokeAllSessions()
    for stale in [generation, credentialGeneration] {
      let granted = await engine.grantSession(for: first, authentication: nil, generation: stale)
      XCTAssertFalse(granted)
    }
  }

  #if os(macOS)
    // No authentication or Keychain access: observe invalidate on an unevaluated test context.
    private final class TestContext: LAContext, @unchecked Sendable {
      private let lock = NSLock()
      private var invalidated = false
      var isInvalidated: Bool { lock.withLock { invalidated } }
      override func invalidate() { lock.withLock { invalidated = true } }
    }

    func testCredentialAndGlobalRevocationInvalidateSavedAuthentications() async {
      let engine = ApprovalEngine()
      let first = request()
      let second = request("other")
      let firstContext = TestContext()
      let secondContext = TestContext()
      for (request, context) in [(first, firstContext), (second, secondContext)] {
        await engine.grantSession(
          for: request, authentication: AuthenticationGrant(context: context),
          generation: await engine.sessionGeneration(for: request))
      }
      await engine.revokeSessions(for: first.credentialIdentifier)
      XCTAssertTrue(firstContext.isInvalidated)
      XCTAssertFalse(secondContext.isInvalidated)
      await engine.revokeAllSessions()
      XCTAssertTrue(secondContext.isInvalidated)
    }

    func testExpiryStillUsesEightHourBoundaryAndInvalidatesAuthentication() async {
      let engine = ApprovalEngine()
      let request = request()
      let context = TestContext()
      let start = Date(timeIntervalSince1970: 1_000_000)
      await engine.grantSession(
        for: request, authentication: AuthenticationGrant(context: context),
        generation: await engine.sessionGeneration(for: request), now: start)
      let before = await engine.sessionApproval(
        for: request, now: start.addingTimeInterval(ApprovalEngine.maxSessionAge - 1))
      XCTAssertNotNil(before)
      XCTAssertFalse(context.isInvalidated)
      let atExpiry = await engine.sessionApproval(
        for: request, now: start.addingTimeInterval(ApprovalEngine.maxSessionAge))
      XCTAssertNil(atExpiry)
      XCTAssertTrue(context.isInvalidated)
      let count = await engine.activeSessionCount(now: start)
      XCTAssertEqual(count, 0)
    }
  #endif
}
