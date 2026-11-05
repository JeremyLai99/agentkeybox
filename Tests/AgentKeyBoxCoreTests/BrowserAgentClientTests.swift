import Foundation
import XCTest

@testable import AgentKeyBoxCore

final class BrowserAgentClientTests: XCTestCase {
  func testRecoveryCLIUsesStoredItemAndOriginalSessionWithoutSecretArguments() throws {
    let browser = UUID()
    let credential = UUID()
    let session = UUID()
    let invocation = try BrowserAgentInvocation(
      arguments: [
        "recover", "--session", session.uuidString, "--browser", browser.uuidString,
        "--credential", credential.uuidString,
      ], workingDirectory: "/project")
    XCTAssertEqual(invocation.request.action, .browserRecover)
    XCTAssertEqual(invocation.request.credentialIdentifier, credential.uuidString)
    XCTAssertEqual(invocation.request.sessionID, session.uuidString)
    XCTAssertEqual(invocation.request.browser?.sessionID, browser)
    for arguments in [
      ["recover", "--session", session.uuidString, "--browser", browser.uuidString],
      [
        "recover", "--session", session.uuidString, "--browser", browser.uuidString,
        "--credential", credential.uuidString, "--code", "do-not-accept",
      ],
    ] {
      XCTAssertThrowsError(
        try BrowserAgentInvocation(arguments: arguments, workingDirectory: "/project"))
    }
    let response = BrokerResponse(ok: true, decision: .deny)
    XCTAssertThrowsError(try BrowserAgentResult(invocation: invocation, response: response))
  }

  func testFixedRecoveryChallengeDoesNotClaimPageReadyOrSuccessfulAuthentication() throws {
    let invocation = try BrowserAgentInvocation(
      arguments: ["login", "--credential", UUID().uuidString], workingDirectory: "/project")
    let page = BrowserPage(
      sessionID: UUID(), status: "recoveryCodeRequired", origin: "https://example.com",
      title: "Recovery code required", text: "No page content", links: [])
    let result = try BrowserAgentResult(
      invocation: invocation,
      response: BrokerResponse(ok: true, decision: .allowOnce, browserPage: page))
    XCTAssertEqual(result.status, "recoveryCodeRequired")
    XCTAssertEqual(result.page, page)
  }

  func testControlledErrorsDistinguishApprovalFromTransportFailureWithoutRawDiagnostics() {
    for message in ["Another AgentKeyBox approval is already pending.", "Approval timed out."] {
      XCTAssertEqual(BrokerError.requestFailed(message).controlledApprovalMessage, message)
      XCTAssertNil(BrokerError.requestFailed(message + " secret-value").controlledApprovalMessage)
    }
    for error in [
      BrokerError.requestTimedOut, .appNotRunning, .invalidResponse,
      .brokerAuthenticationUnavailable, .requestFailed("secret-value"),
      .requestFailed("HTTP error: private response body"),
    ] {
      XCTAssertNil(error.controlledApprovalMessage)
    }
  }

  func testSeparateCLIProcessesCanContinueOnlyTheOriginalOwnerAndProject() throws {
    let login = try BrowserAgentInvocation(
      arguments: ["login", "--credential", UUID().uuidString, "--project", "/work/project"],
      workingDirectory: "/different")
    let browser = UUID()
    let session = try XCTUnwrap(login.request.sessionID)
    let follow = try BrowserAgentInvocation(
      arguments: [
        "follow", "--session", session, "--browser", browser.uuidString,
        "--link", UUID().uuidString, "--project", "/work/project/./",
      ], workingDirectory: "/different")
    let owner = try BrowserOwner(
      agentID: login.request.agentID, projectPath: login.request.projectPath, sessionID: session)
    let lease = BrowserLease(owner: owner)
    try lease.authorize(
      BrowserOwner(
        agentID: follow.request.agentID, projectPath: follow.request.projectPath,
        sessionID: try XCTUnwrap(follow.request.sessionID)))
    XCTAssertEqual(follow.request.browser?.sessionID, browser)
    XCTAssertEqual(follow.request.action, .browserFollow)
    XCTAssertEqual(follow.request.requestedScope, .once)
    for (agent, project, sessionID) in [
      ("codex", "/work/project", session),
      ("akb-browser", "/other", session),
      ("akb-browser", "/work/project", UUID().uuidString),
    ] {
      XCTAssertThrowsError(
        try lease.authorize(
          BrowserOwner(agentID: agent, projectPath: project, sessionID: sessionID)))
    }
  }

  func testRejectsSecretInputsUnknownFlagsDuplicateFlagsAndInvalidHandles() throws {
    let id = UUID().uuidString
    let cases: [[String]] = [
      ["login"], ["login", "--credential", "password"],
      ["login", "--credential", id, "--password", "secret"],
      ["login", "--credential", id, "--credential", id],
      ["login", "--credential", id, "--url", "https://example.com"],
      ["login", "--credential", id, "--agent", "codex"],
      ["login", "--credential", id, "--session", id],
      ["login", "--credential", id, "--purpose", String(repeating: "x", count: 2049)],
      ["read", "--session", id, "--browser", id, "--script", "document.cookie"],
      ["follow", "--session", id, "--browser", id],
      ["close", "--session", id, "--browser", "invalid"],
      ["list", "--project", "relative/path"], ["list", "--project", "/bad\0path"],
      ["list", "--project"], ["list", "--project", ""],
    ]
    for args in cases {
      XCTAssertThrowsError(try BrowserAgentInvocation(arguments: args, workingDirectory: "/work"))
    }
  }

  func testOutputOmitsRawBrokerFieldsAndRequiresAnApprovedPage() throws {
    let invocation = try BrowserAgentInvocation(
      arguments: ["login", "--credential", UUID().uuidString], workingDirectory: "/work")
    let page = BrowserPage(
      sessionID: UUID(), status: "pageReady", origin: "https://example.com",
      title: "Account", text: "Welcome", links: [])
    var response = BrokerResponse(
      ok: true, error: "diagnostic-secret", decision: .allowOnce,
      environment: ["PASSWORD": "secret-value"], browserPage: page)
    let result = try BrowserAgentResult(invocation: invocation, response: response)
    let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    XCTAssertFalse(encoded.contains("diagnostic-secret"))
    XCTAssertFalse(encoded.contains("secret-value"))
    XCTAssertFalse(encoded.contains("PASSWORD"))
    XCTAssertEqual(result.clientSessionID, invocation.request.sessionID)
    XCTAssertEqual(result.page, page)
    response.decision = nil
    XCTAssertThrowsError(try BrowserAgentResult(invocation: invocation, response: response))
    response.decision = .deny
    XCTAssertThrowsError(try BrowserAgentResult(invocation: invocation, response: response))
    response.decision = .allowOnce
    response.browserPage = nil
    XCTAssertThrowsError(try BrowserAgentResult(invocation: invocation, response: response))
  }

  func testReadRejectsWrongBrowserAndListOnlyReturnsWebsiteLogins() throws {
    let read = try BrowserAgentInvocation(
      arguments: ["read", "--session", UUID().uuidString, "--browser", UUID().uuidString],
      workingDirectory: "/work")
    let response = BrokerResponse(
      ok: true,
      browserPage: BrowserPage(
        sessionID: UUID(), status: "pageReady", origin: "https://example.com", title: "",
        text: "", links: []))
    XCTAssertThrowsError(try BrowserAgentResult(invocation: read, response: response))
    let list = try BrowserAgentInvocation(arguments: ["list"], workingDirectory: "/work")
    let credentials = [CredentialKind.login, .apiKey, .creditCard, .recoveryCodes].map {
      CredentialSummary(metadata: CredentialMetadata(label: "Item", service: "Example", kind: $0))
    }
    let result = try BrowserAgentResult(
      invocation: list, response: BrokerResponse(ok: true, credentials: credentials))
    XCTAssertEqual(result.logins?.map(\.kind), [.login])
    XCTAssertEqual(result.recoveryCodeSets?.map(\.kind), [.recoveryCodes])
    XCTAssertNil(result.page)
    XCTAssertNil(result.clientSessionID)
  }
}
