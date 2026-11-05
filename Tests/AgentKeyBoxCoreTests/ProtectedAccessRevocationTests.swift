import XCTest

@testable import AgentKeyBoxCore

final class ProtectedAccessRevocationTests: XCTestCase {
  func testPendingSubmissionCancelsButStartedSubmissionKeepsItsActualOutcome() {
    let id = UUID()
    var pending = AgentRequest(
      agentID: "fixture", agentDisplayName: "Fixture", projectPath: "/fixture",
      credentialIdentifier: id.uuidString, purpose: "Synthetic submission")
    pending.kind = .sensitiveSubmission
    func plan(_ removed: UUID, executing: UUID?) -> ProtectedAccessRevocation {
      ProtectedAccessRevocation(
        credentialID: removed, pending: pending, broker: nil,
        executingSubmissionID: executing, browserCredentials: [:])
    }
    XCTAssertTrue(plan(id, executing: nil).cancelSubmission)
    XCTAssertTrue(plan(id, executing: UUID()).cancelSubmission)
    XCTAssertFalse(plan(id, executing: pending.id).cancelSubmission)
    XCTAssertFalse(plan(UUID(), executing: nil).cancelSubmission)
  }

  func testRemovingLoginClosesAllItsBrowsersAndRecoveryRemovalClosesPendingBrowserOnly() {
    let login = UUID()
    let recovery = UUID()
    let first = UUID()
    let second = UUID()
    let unrelated = UUID()
    let browsers = [first: login, second: login, unrelated: UUID()]
    var pending = AgentRequest(
      agentID: "fixture", agentDisplayName: "Fixture", projectPath: "/fixture",
      credentialIdentifier: recovery.uuidString, purpose: "Synthetic recovery")
    pending.kind = .browserRecovery
    var broker = BrokerRequest(
      action: .browserRecover, agentID: "fixture", agentDisplayName: "Fixture",
      projectPath: "/fixture", credentialIdentifier: recovery.uuidString)
    broker.browser = BrowserCommand(sessionID: first)
    func plan(_ id: UUID) -> ProtectedAccessRevocation {
      ProtectedAccessRevocation(
        credentialID: id, pending: pending, broker: broker, executingSubmissionID: nil,
        browserCredentials: browsers)
    }
    XCTAssertEqual(plan(login).browserIDs, [first, second])
    XCTAssertEqual(plan(recovery).browserIDs, [first])
    XCTAssertTrue(plan(recovery).cancelBrowserApproval)
    XCTAssertFalse(plan(recovery).cancelSubmission)
    XCTAssertTrue(plan(UUID()).browserIDs.isEmpty)
    XCTAssertFalse(plan(UUID()).cancelBrowserApproval)
  }
}
