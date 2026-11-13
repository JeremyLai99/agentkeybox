import XCTest

@testable import AgentKeyBoxCore

final class CredentialUsePolicyTests: XCTestCase {
  func testBrowserClosureAfterExecutionNeverSuggestsAnotherSignIn() {
    for error in [ControlledBrowserError.unavailable, .expired, .invalidLink, .failed] {
      XCTAssertEqual(ControlledBrowserError.forOperation(error, executionStarted: true), .failed)
      XCTAssertEqual(ControlledBrowserError.forOperation(error, executionStarted: false), error)
    }
    XCTAssertEqual(
      ControlledBrowserError.forOperation(CancellationError(), executionStarted: true), .failed)
  }

  func testBeforeExecutionChangedCredentialRequiresApprovalAgain() {
    XCTAssertEqual(
      CredentialUsePolicy.failureDisposition(executionStarted: false, credentialIsCurrent: false),
      .credentialChanged)
  }

  func testExecutionFailureAfterCredentialChangeNeverSuggestsReapproval() {
    for isCurrent in [false, true] {
      XCTAssertEqual(
        CredentialUsePolicy.failureDisposition(
          executionStarted: true, credentialIsCurrent: isCurrent),
        .operationFailed)
    }
  }

  func testPreparationFailureWithUnchangedCredentialKeepsItsOwnError() {
    XCTAssertEqual(
      CredentialUsePolicy.failureDisposition(executionStarted: false, credentialIsCurrent: true),
      .operationFailed)
  }

  private let project = Project(name: "Synthetic", rootPath: "/tmp/akb-policy-project")

  private func item() -> CredentialMetadata {
    CredentialMetadata(
      label: "Synthetic key", service: "Fixture", projectID: project.id,
      environmentVariableName: "FIXTURE_KEY", allowedHosts: ["fixture.invalid"])
  }

  private func permitted(_ approved: [CredentialMetadata], _ current: [CredentialMetadata]) -> Bool
  {
    CredentialUsePolicy.isCurrent(
      approved: approved, current: current, projects: [project],
      projectPath: project.rootPath, isRevoked: false)
  }

  func testUnchangedVisibleCredentialIsAllowed() {
    let original = item()
    XCTAssertTrue(permitted([original], [original]))
  }

  func testEveryMetadataChangeAfterReadRejectsUseIncludingTimestampAndHosts() {
    let original = item()
    let mutations: [(inout CredentialMetadata) -> Void] = [
      { $0.updatedAt = $0.updatedAt.addingTimeInterval(1) },
      { $0.allowedHosts = ["different.invalid"] },
      { $0.projectID = nil },
      { $0.projectID = UUID() },
      { $0.label = "Edited" },
      { $0.settings = ["FIXTURE_URL": "https://different.invalid"] },
      { $0.environmentVariableName = "OTHER_KEY" },
      { $0.payloadRevision = UUID() },
      { $0.kind = .login },
    ]
    for mutate in mutations {
      var changed = original
      mutate(&changed)
      XCTAssertFalse(permitted([original], [changed]))
    }
    XCTAssertFalse(permitted([original], []))
  }

  func testProjectRemovalOrChangedRootRejectsOtherwiseIdenticalMetadata() {
    let original = item()
    var moved = project
    moved.rootPath = "/tmp/other-policy-project"
    for projects in [[], [moved]] {
      XCTAssertFalse(
        CredentialUsePolicy.isCurrent(
          approved: [original], current: [original], projects: projects,
          projectPath: project.rootPath, isRevoked: false))
    }
    XCTAssertFalse(
      CredentialUsePolicy.isCurrent(
        approved: [original], current: [original], projects: [project],
        projectPath: project.rootPath + "-outside", isRevoked: false))
  }

  func testRevocationRejectsEvenUnchangedGlobalCredential() {
    var original = item()
    original.projectID = nil
    XCTAssertFalse(
      CredentialUsePolicy.isCurrent(
        approved: [original], current: [original], projects: [],
        projectPath: project.rootPath, isRevoked: true))
  }

  func testEnvironmentRechecksEarlierReadsWhenLaterCredentialReadCompletes() {
    let first = item()
    let second = item()
    XCTAssertTrue(permitted([first, second], [first, second]))
    var changedFirst = first
    changedFirst.updatedAt = first.updatedAt.addingTimeInterval(1)
    XCTAssertFalse(permitted([first, second], [changedFirst, second]))
    XCTAssertFalse(permitted([first, second], [second]))
  }
}
