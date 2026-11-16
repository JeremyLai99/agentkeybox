import Foundation
import XCTest

@testable import AgentKeyBoxCore

final class BrowserRecoveryTests: XCTestCase {
  func testLinkedRecoveryRequiresSameLoginProjectAndOriginButNotPath() throws {
    let login = CredentialMetadata(
      label: "Login", service: "Test", projectID: UUID(), kind: .login,
      loginURL: "https://example.com/login")
    let item = CredentialMetadata(
      label: "Codes", service: "Test", projectID: login.projectID, kind: .recoveryCodes,
      linkedLoginID: login.id)
    let target = try XCTUnwrap(URL(string: "https://example.com/sessions/two-factor/recovery"))
    try BrowserRecoveryPolicy.validate(
      item, target: target, origin: "https://example.com", login: login)
    for target in [
      "https://other.example.com/recovery", "https://example.com:444/recovery",
      "http://example.com/recovery",
    ] {
      XCTAssertThrowsError(
        try BrowserRecoveryPolicy.validate(
          item, target: XCTUnwrap(URL(string: target)), origin: "https://example.com", login: login)
      ) {
        XCTAssertEqual($0 as? ControlledBrowserError, .unavailable)
      }
    }
    var other = login
    other.loginURL = "https://elsewhere.invalid/login"
    var moved = login
    moved.projectID = UUID()
    for login in [
      nil, other, moved,
      CredentialMetadata(label: "Other", service: "Test", kind: .login, loginURL: login.loginURL),
    ] {
      XCTAssertThrowsError(
        try BrowserRecoveryPolicy.validate(
          item, target: target, origin: "https://example.com", login: login)
      ) {
        XCTAssertEqual($0 as? ControlledBrowserError, .recoveryNotLinkedToLogin)
      }
    }
    // The agent sees fixed English guidance, and only these exact messages cross MCP.
    let message = try XCTUnwrap(ControlledBrowserError.recoveryNotLinkedToLogin.agentMessage)
    XCTAssertEqual(BrokerError.requestFailed(message).controlledApprovalMessage, message)
    XCTAssertNil(BrokerError.requestFailed("Some raw diagnostic").controlledApprovalMessage)
    XCTAssertNotNil(ControlledBrowserError.recoveryCodesExhausted.agentMessage)
    XCTAssertThrowsError(
      try SensitiveSubmissionPolicy.validate(
        .init(fields: ["code": "{{recovery.code}}"]), credential: item)
    ) {
      XCTAssertEqual($0 as? SensitiveDataError, .browserRecoveryOnly)
    }
    var manual = item
    manual.submissionURL = target.absoluteString
    XCTAssertEqual(
      try SensitiveSubmissionPolicy.validate(
        .init(fields: ["code": "{{recovery.code}}"]), credential: manual), target)
  }

  func testLoginChoicesAndDeletingLoginUnlinksWithoutDeletingCodes() {
    let projectID = UUID()
    let login = CredentialMetadata(
      label: "Login", service: "Test", projectID: projectID,
      kind: .login, loginURL: "https://example.com/login")
    let codes = CredentialMetadata(
      label: "Codes", service: "Test", projectID: projectID,
      kind: .recoveryCodes, linkedLoginID: login.id)
    let other = CredentialMetadata(
      label: "Other", service: "Test", kind: .login,
      loginURL: "https://example.com/login")
    let incomplete = CredentialMetadata(
      label: "Incomplete", service: "Test", projectID: projectID,
      kind: .login)
    var snapshot = MetadataSnapshot(credentials: [login, codes, other, incomplete])
    XCTAssertEqual(
      BrowserRecoveryPolicy.logins(in: snapshot.credentials, projectID: projectID), [login])
    snapshot.removeCredential(id: login.id)
    let retained = snapshot.credentials.first { $0.id == codes.id }
    XCTAssertNotNil(retained)
    XCTAssertNil(retained?.linkedLoginID)
    XCTAssertNil(retained?.submissionURL)
    XCTAssertEqual(snapshot.credentials.count, 3)
    XCTAssertTrue(snapshot.credentials.contains(other))
  }

  func testOldMetadataDecodesWithoutLinkAndSummaryContainsOnlyReference() throws {
    let old = CredentialMetadata(label: "Old", service: "Test", kind: .recoveryCodes)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    object.removeValue(forKey: "linkedLoginID")
    object.removeValue(forKey: "recoveryCodeCounts")
    object.removeValue(forKey: "recoveryCodePendingRevision")
    let decoded = try JSONDecoder().decode(
      CredentialMetadata.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(decoded.linkedLoginID)
    XCTAssertNil(decoded.recoveryCodeCounts)
    XCTAssertNil(decoded.recoveryCodePendingRevision)
    XCTAssertTrue(
      CredentialSummary(metadata: decoded).recoveryListingFields.contains("codes=unknown"))
    var linked = decoded
    linked.linkedLoginID = UUID()
    let summary = CredentialSummary(metadata: linked)
    XCTAssertEqual(
      try JSONDecoder().decode(CredentialSummary.self, from: JSONEncoder().encode(summary)), summary
    )
    XCTAssertTrue(
      summary.recoveryListingFields.contains("for_login=\(linked.linkedLoginID!.uuidString)"))
    XCTAssertTrue(summary.recoveryListingFields.contains("use=browser_recover"))
    XCTAssertTrue(
      summary.recoveryListingFields.contains {
        $0.hasPrefix("submission_url=") && $0.contains("browser_recover")
      })
    XCTAssertTrue(CredentialSummary(metadata: old).recoveryListingFields.contains("for_login=-"))
  }

  func testChallengeGuidanceUsesOnlyFixedTextAndMatchingItems() throws {
    let login = CredentialMetadata(
      label: "Login", service: "Test", kind: .login,
      loginURL: "https://example.com/login")
    let target = try XCTUnwrap(URL(string: "https://example.com/recovery"))
    let linked = CredentialMetadata(
      label: "Private label", service: "Test", kind: .recoveryCodes,
      linkedLoginID: login.id)
    let manual = CredentialMetadata(
      label: "Manual", service: "Test", kind: .recoveryCodes,
      submissionURL: target.absoluteString)
    let sessionID = UUID()
    func page(_ items: [CredentialMetadata]) -> BrowserPage {
      BrowserRecoveryPolicy.recoveryPage(
        sessionID: sessionID, origin: "https://example.com",
        target: target, login: login, candidates: items)
    }
    XCTAssertEqual(page([linked]), page([manual]))
    XCTAssertNotEqual(page([]).text, page([linked]).text)
    XCTAssertFalse(page([linked]).text.contains(linked.label))
    XCTAssertTrue(page([]).links.isEmpty)
    XCTAssertEqual(page([]).status, "recoveryCodeRequired")
  }

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
