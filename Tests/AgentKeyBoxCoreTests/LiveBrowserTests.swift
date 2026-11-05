#if os(macOS)
  import AppKit
  import Foundation
  import XCTest

  @testable import AgentKeyBoxCore

  /// Opt-in network checks, never a dependency of offline CI. The public sample account is
  /// advertised on the fixture's login page. No personal credentials or Keychain items are used.
  final class LiveBrowserTests: XCTestCase {
    private func requireOptIn() throws {
      try XCTSkipUnless(
        ProcessInfo.processInfo.environment["AGENTKEYBOX_LIVE_BROWSER_TESTS"] == "1",
        "Set AGENTKEYBOX_LIVE_BROWSER_TESTS=1 to contact the public demo and GitHub login page.")
    }

    @MainActor func testPublicDemoLoginWithProductionTLS() async throws {
      try requireOptIn()
      _ = NSApplication.shared
      let payload = SensitivePayload(
        login: try StoredLogin(username: "tomsmith", password: "SuperSecretPassword!"))
      let credential = CredentialMetadata(
        label: "Public login demonstration", service: "The Internet", kind: .login,
        loginURL: "https://the-internet.herokuapp.com/login", payloadRevision: payload.revision)
      let browser = try ControlledBrowserSession(
        credential: credential,
        owner: BrowserOwner(
          agentID: "live-test", projectPath: "/fixture", sessionID: UUID().uuidString))
      defer { browser.close() }
      try await browser.prepare()
      XCTAssertEqual(
        browser.submissionURL?.absoluteString, "https://the-internet.herokuapp.com/authenticate")
      let page = try await browser.signIn(payload: payload)
      XCTAssertTrue(page.text.contains("Secure Area"))
      // This marker is behind the server's session check, after the private browser is recreated.
      XCTAssertTrue(page.text.contains("Welcome to the Secure Area"))
      let json = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
      XCTAssertFalse(json.contains(payload.login!.username))
      XCTAssertFalse(json.contains(payload.login!.password))
      XCTAssertTrue(page.links.contains { $0.text.contains("Logout") })
      let reread = try await browser.read()
      XCTAssertTrue(reread.text.contains("Welcome to the Secure Area"))
      browser.close()
      do {
        _ = try await browser.read()
        XCTFail("Closed session must not be readable")
      } catch {}
    }

    @MainActor func testGitHubLoginPreflightWithoutCredentialsOrSubmission() async throws {
      try requireOptIn()
      _ = NSApplication.shared
      let credential = CredentialMetadata(
        label: "GitHub preflight only", service: "GitHub", kind: .login,
        loginURL: "https://github.com/login", payloadRevision: UUID())
      let browser = try ControlledBrowserSession(
        credential: credential,
        owner: BrowserOwner(
          agentID: "live-test", projectPath: "/fixture", sessionID: UUID().uuidString))
      defer { browser.close() }
      try await browser.prepare()
      XCTAssertEqual(browser.lease.phase, .awaitingApproval)
      XCTAssertEqual(browser.submissionURL?.absoluteString, "https://github.com/session")
      // Deliberately never signIn: this check does not establish GitHub authentication or 2FA support.
    }
  }
#endif
