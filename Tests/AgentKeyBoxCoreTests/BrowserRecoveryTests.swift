import Foundation
import XCTest

@testable import AgentKeyBoxCore

final class BrowserRecoveryTests: XCTestCase {
  func testRecoveryRequiresExactConfiguredEndpointAndKind() throws {
    let target = try XCTUnwrap(URL(string: "https://example.com/recover"))
    let item = CredentialMetadata(
      label: "Recovery", service: "Test", kind: .recoveryCodes,
      submissionURL: target.absoluteString)
    try BrowserRecoveryPolicy.validate(item, target: target, origin: "https://example.com")
    for path in [
      "https://example.com/other", "https://elsewhere.invalid/recover", "",
      "http://example.com/recover",
    ] {
      var changed = item
      changed.submissionURL = path
      XCTAssertThrowsError(
        try BrowserRecoveryPolicy.validate(changed, target: target, origin: "https://example.com"))
    }
    var changed = item
    changed.kind = .creditCard
    XCTAssertThrowsError(
      try BrowserRecoveryPolicy.validate(changed, target: target, origin: "https://example.com"))
    XCTAssertThrowsError(
      try BrowserRecoveryPolicy.validate(item, target: target, origin: "https://elsewhere.invalid"))
  }

  func testReservationPersistsBeforeReleaseAndCannotReuseIssuedCodeAfterReload() throws {
    let payload = SensitivePayload(
      recoveryCodes: try RecoveryCodeSet(text: "fixture-recovery-001\nfixture-recovery-002"))
    var item = CredentialMetadata(
      label: "Recovery", service: "Test", kind: .recoveryCodes, payloadRevision: payload.revision)
    var saved: Data?
    let first = try BrowserRecoveryPolicy.reserve(payload: payload, credential: item) { saved = $0 }
    let reloaded = try SensitivePayload.decode(XCTUnwrap(saved), kind: .recoveryCodes)
    XCTAssertEqual(reloaded.recoveryCodes?.entries.map(\.status), [.issued, .available])
    XCTAssertNotEqual(reloaded.revision, payload.revision)
    item.payloadRevision = reloaded.revision
    let next = try BrowserRecoveryPolicy.reserve(payload: reloaded, credential: item) { saved = $0 }
    XCTAssertNotEqual(first, next)
    let exhausted = try SensitivePayload.decode(XCTUnwrap(saved), kind: .recoveryCodes)
    item.payloadRevision = exhausted.revision
    XCTAssertThrowsError(
      try BrowserRecoveryPolicy.reserve(payload: exhausted, credential: item) { _ in
        XCTFail("No available code")
      })
    item.payloadRevision = payload.revision
    XCTAssertThrowsError(
      try BrowserRecoveryPolicy.reserve(payload: payload, credential: item) { _ in
        throw SensitiveDataError.invalidPayload
      })
    var stale = item
    stale.payloadRevision = UUID()
    XCTAssertThrowsError(
      try BrowserRecoveryPolicy.reserve(payload: payload, credential: stale) { _ in
        XCTFail("Stale revision must not save")
      })
  }

  func testRecoveryApprovalHasNoStandingGrantAndShowsExactDestination() {
    let item = CredentialMetadata(label: "Recovery", service: "Test", kind: .recoveryCodes)
    var request = AgentRequest(
      agentID: "agent", agentDisplayName: "Agent", projectPath: "/project",
      credentialIdentifier: item.id.uuidString, operation: "Website account", sessionID: "session")
    request.kind = .browserRecovery
    request.url = "https://example.com/recover"
    let presentation = ApprovalPresentation.make(
      for: request, credential: item, projectName: nil, risk: nil)
    XCTAssertTrue(presentation.denyIsDefault)
    XCTAssertNil(presentation.sessionApprovalLabel)
    XCTAssertFalse(ApprovalEngine.canGrantSession(for: request))
    XCTAssertTrue(presentation.facts.contains { $0.value == request.url })
    XCTAssertTrue(presentation.facts.contains { $0.value == request.operation })
  }
}
