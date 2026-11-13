import Foundation
import XCTest

@testable import AgentKeyBoxCore

final class BrowserPolicyTests: XCTestCase {
  func testLoginEnvelopeStaysOutOfDeveloperToolsAndRoundTrips() throws {
    let payload = SensitivePayload(login: try StoredLogin(username: "user", password: "password"))
    let data = try payload.encoded()
    XCTAssertEqual(try SensitivePayload.decode(data, kind: .login), payload)
    XCTAssertEqual(SensitivePayload.importedKind(data), .login)
    XCTAssertEqual(SensitivePayload.importedKind(Data(), filename: "broken.login.json"), .login)
    XCTAssertThrowsError(try SensitivePayload.decode(data, kind: .creditCard))
    XCTAssertThrowsError(try StoredLogin(username: "", password: "password"))
    var metadata = CredentialMetadata(
      label: "Account", service: "Website", kind: .login,
      environmentVariableName: "LOGIN", settings: ["username": "private"],
      submissionURL: "https://example.com/post", loginURL: "https://example.com/login",
      payloadRevision: payload.revision)
    XCTAssertNil(metadata.injectionVariableName)
    XCTAssertNil(CredentialSummary(metadata: metadata).settings)
    XCTAssertThrowsError(
      try SensitiveSubmissionPolicy.validate(
        .init(fields: ["code": "{{recovery.code}}"]), credential: metadata))
    metadata.submissionURL = nil
    let summary = String(
      decoding: try JSONEncoder().encode(CredentialSummary(metadata: metadata)), as: UTF8.self)
    XCTAssertFalse(summary.contains("password"))
    XCTAssertFalse(summary.contains("private"))
    let contents = BackupContents(
      projects: [], credentials: [metadata], secrets: [metadata.id.uuidString: data])
    let entries = try BackupArchive.layout(contents)
    XCTAssertTrue(entries.contains { $0.path.hasSuffix(".login.json") })
    let archive = try XCTUnwrap(entries.first { $0.path == BackupArchive.dataFileName })
    let restored = try BackupArchive.contents(fromDataFile: archive.data)
    XCTAssertEqual(restored.credentials.first?.loginURL, metadata.loginURL)
    XCTAssertEqual(try SensitivePayload.restored(data, kind: .login), data)
  }

  func testOriginBindingRejectsOtherPortsSchemesAndAuthorityTricks() throws {
    let website = try BrowserPolicy.loginURL("https://example.com/login")
    let origin = try XCTUnwrap(BrowserPolicy.origin(website))
    XCTAssertTrue(
      BrowserPolicy.permits(URL(string: "https://example.com:443/account")!, origin: origin))
    for value in [
      "http://example.com/login", "https://example.com:8443/account",
      "https://example.com.evil.invalid/", "https://user@example.com/", "file:///tmp/page",
      "javascript:alert(1)", "https://other.example.com/",
    ] {
      XCTAssertFalse(BrowserPolicy.permits(URL(string: value)!, origin: origin), value)
    }
    for value in [
      "https://example.com/login?token=value", "https://example.com/login#fragment",
      "http://localhost/login",
    ] {
      XCTAssertThrowsError(try BrowserPolicy.loginURL(value))
    }
  }

  func testLeaseNeverExposesAuthenticationAndCannotReopenAfterRevocation() throws {
    let owner = try BrowserOwner(agentID: "agent", projectPath: "/project", sessionID: "session")
    let now = Date()
    var lease = BrowserLease(owner: owner, now: now)
    XCTAssertThrowsError(try lease.transition(from: .ready, to: .reading))
    try lease.transition(from: .preparing, to: .awaitingApproval)
    try lease.transition(from: .awaitingApproval, to: .authenticating)
    XCTAssertThrowsError(try lease.transition(from: .ready, to: .reading))
    XCTAssertThrowsError(
      try lease.authorize(
        BrowserOwner(agentID: "agent", projectPath: "/other", sessionID: "session")))
    XCTAssertThrowsError(
      try lease.authorize(
        BrowserOwner(agentID: "agent", projectPath: "/project", sessionID: "other")))
    XCTAssertThrowsError(
      try lease.authorize(owner, now: now.addingTimeInterval(BrowserPolicy.lifetime)))
    lease.close()
    XCTAssertThrowsError(try lease.transition(from: .closed, to: .ready))
    XCTAssertThrowsError(try lease.authorize(owner))
  }

  func testReflectionRedactionIncludesShortOverlappingAndTruncatedValues() throws {
    let login = try StoredLogin(username: "test", password: "test-password")
    XCTAssertFalse(BrowserPolicy.redact("test-password test", login: login).contains("password"))
    for encoded in SecretRedactor.candidates(for: Data(login.password.utf8)) {
      XCTAssertFalse(BrowserPolicy.redact("value: " + encoded, login: login).contains(encoded))
    }
    XCTAssertEqual(
      BrowserPolicy.redact("value: test-pass", login: login, captureWasCut: true), "value: ")
    let short = try StoredLogin(username: "u", password: "p")
    XCTAssertFalse(BrowserPolicy.redact("u p", login: short).contains("u p"))
  }

  func testBrowserApprovalNeverOffersStandingGrant() {
    for kind in [AgentRequestKind.browserLogin, .browserFollow] {
      var request = AgentRequest(
        agentID: "agent", agentDisplayName: "Agent", projectPath: "/project",
        credentialIdentifier: UUID().uuidString, sessionID: "session")
      request.kind = kind
      request.url = "https://example.com/session"
      let presentation = ApprovalPresentation.make(
        for: request, credential: nil, projectName: nil, risk: nil)
      XCTAssertTrue(presentation.denyIsDefault)
      XCTAssertNil(presentation.sessionApprovalLabel)
      XCTAssertFalse(ApprovalEngine.canGrantSession(for: request))
    }
  }
}

#if os(macOS)
  import AppKit
  import WebKit

  /// Trust is overridden ONLY in the test subclass, pinned to this test's ephemeral leaf.
  /// Production uses the ordinary system trust decision; no trust bypass or HTTP flag ships.
  @MainActor
  private final class FixtureBrowser: ControlledBrowserSession {
    var certificate: SecCertificate?
    override func webView(
      _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
      completionHandler:
        @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
      guard challenge.protectionSpace.host == "127.0.0.1", let certificate,
        let trust = challenge.protectionSpace.serverTrust,
        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
        let leaf = chain.first, SecCertificateCopyData(leaf) == SecCertificateCopyData(certificate)
      else {
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
      SecTrustSetAnchorCertificatesOnly(trust, true)
      guard SecTrustEvaluateWithError(trust, nil) else {
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      completionHandler(.useCredential, URLCredential(trust: trust))
    }
  }

  private final class BrowserFixture {
    let directory: URL
    let process = Process()
    let port: Int
    let certificate: SecCertificate

    init() throws {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "akb-browser-test-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let cleanupDirectory = directory
      let cleanupProcess = process
      var started = false
      defer {
        if !started {
          if cleanupProcess.isRunning {
            cleanupProcess.terminate()
            cleanupProcess.waitUntilExit()
          }
          try? FileManager.default.removeItem(at: cleanupDirectory)
        }
      }
      let config = directory.appendingPathComponent("openssl.cnf")
      try """
      [req]
      distinguished_name=dn
      x509_extensions=v3
      prompt=no
      [dn]
      CN=127.0.0.1
      [v3]
      subjectAltName=IP:127.0.0.1
      basicConstraints=critical,CA:TRUE
      keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
      extendedKeyUsage=serverAuth
      """.write(to: config, atomically: true, encoding: .utf8)
      let cert = directory.appendingPathComponent("cert.pem")
      let key = directory.appendingPathComponent("key.pem")
      let openssl = Process()
      openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
      openssl.arguments = [
        "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", config.path,
        "-keyout", key.path, "-out", cert.path,
      ]
      openssl.standardOutput = FileHandle.nullDevice
      openssl.standardError = FileHandle.nullDevice
      try openssl.run()
      openssl.waitUntilExit()
      guard openssl.terminationStatus == 0 else { throw ControlledBrowserError.failed }
      let pem = try String(contentsOf: cert, encoding: .utf8)
      let base64 = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("---") }.joined()
      certificate = try XCTUnwrap(
        SecCertificateCreateWithData(nil, XCTUnwrap(Data(base64Encoded: base64)) as CFData))
      let output = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      process.arguments = [
        try XCTUnwrap(Bundle.module.url(forResource: "browser_fixture", withExtension: "py")).path,
        cert.path, key.path, directory.appendingPathComponent("cross-origin-request").path,
      ]
      process.standardOutput = output
      process.standardError = FileHandle.standardError
      try process.run()
      let data = output.fileHandleForReading.availableData
      port = try XCTUnwrap(
        Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
      started = true
    }

    deinit {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
      try? FileManager.default.removeItem(at: directory)
    }

    @MainActor func browser(path: String = "/login") throws -> (FixtureBrowser, SensitivePayload) {
      _ = NSApplication.shared
      let payload = SensitivePayload(
        login: try StoredLogin(username: "fixture-user", password: "synthetic-password-42!"))
      let credential = CredentialMetadata(
        label: "Synthetic fixture", service: "Test", kind: .login,
        loginURL: "https://127.0.0.1:\(port)\(path)", payloadRevision: payload.revision)
      let browser = try FixtureBrowser(
        credential: credential,
        owner: BrowserOwner(agentID: "test", projectPath: "/fixture", sessionID: "session"))
      browser.certificate = certificate
      return (browser, payload)
    }
  }

  final class ControlledBrowserRuntimeTests: XCTestCase {
    #if DEBUG
      @MainActor func testSubmissionFixturePinsOnlyItsExactProfileDestinationAndCertificate()
        async throws
      {
        let server = try BrowserFixture()
        let profile = DevelopmentProfile(id: UUID())
        let manager = FileManager.default
        try manager.createDirectory(
          at: profile.directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: profile.directory) }
        XCTAssertNil(try DevelopmentSubmissionFixture.load(profile: profile))
        func configure(_ id: UUID, _ port: Int) throws {
          try JSONEncoder().encode(
            DevelopmentSubmissionFixture.Configuration(profileID: id, port: port)
          ).write(to: profile.file("submission-fixture.json"))
        }
        try (SecCertificateCopyData(server.certificate) as Data).write(
          to: profile.file("fixture-cert.der"))
        try configure(UUID(), server.port)
        XCTAssertThrowsError(try DevelopmentSubmissionFixture.load(profile: profile))
        try configure(profile.id, 443)
        XCTAssertThrowsError(try DevelopmentSubmissionFixture.load(profile: profile))
        try configure(profile.id, server.port)
        let fixture = try XCTUnwrap(DevelopmentSubmissionFixture.load(profile: profile))
        let item = CredentialMetadata(
          id: profile.fixtureID(1), label: "QA", service: "Test", kind: .creditCard,
          submissionURL: fixture.origin + "/submit/card")
        XCTAssertNoThrow(try fixture.validate(item))
        let unrelated = CredentialMetadata(
          label: "Other item", service: "Test", kind: .creditCard,
          submissionURL: item.submissionURL)
        XCTAssertThrowsError(try fixture.validate(unrelated))
        var request = URLRequest(url: URL(string: fixture.origin + "/submit/card")!)
        request.httpMethod = "POST"
        request.httpBody = Data("synthetic=test".utf8)
        let marker = server.directory.appendingPathComponent("cross-origin-request.post")
        let ordinary = await SensitiveSubmissionTransport.send(request)
        XCTAssertEqual(ordinary, .unknown)
        XCTAssertFalse(manager.fileExists(atPath: marker.path))
        // The existing fixture rejects these fields with HTTP 400: a rejection proves actual TLS/POST.
        let pinned = await SensitiveSubmissionTransport.send(request, fixture: fixture)
        XCTAssertEqual(pinned, .rejected)
        XCTAssertTrue(manager.fileExists(atPath: marker.path))
        try manager.removeItem(at: marker)
        var otherPath = request
        otherPath.url = URL(string: fixture.origin + "/other")!
        let wrongPath = await SensitiveSubmissionTransport.send(otherPath, fixture: fixture)
        XCTAssertEqual(wrongPath, .unknown)
        XCTAssertFalse(manager.fileExists(atPath: marker.path))
        let other = try BrowserFixture()
        try (SecCertificateCopyData(other.certificate) as Data).write(
          to: profile.file("fixture-cert.der"))
        let wrongFixture = try XCTUnwrap(DevelopmentSubmissionFixture.load(profile: profile))
        let wrongCertificate = await SensitiveSubmissionTransport.send(
          request, fixture: wrongFixture)
        XCTAssertEqual(wrongCertificate, .unknown)
        XCTAssertFalse(manager.fileExists(atPath: marker.path))
      }

      @MainActor func testNativeRecoveryFixtureRequiresMatchingProfileAndPinnedLeaf() async throws {
        let server = try BrowserFixture()
        let profile = DevelopmentProfile(id: UUID())
        let manager = FileManager.default
        try manager.createDirectory(
          at: profile.directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: profile.directory) }
        XCTAssertNil(try DevelopmentRecoveryFixture.load(profile: profile))
        func configure(_ id: UUID, _ port: Int) throws {
          try JSONEncoder().encode(
            DevelopmentRecoveryFixture.Configuration(profileID: id, port: port)
          ).write(to: profile.file("recovery-fixture.json"))
        }
        try (SecCertificateCopyData(server.certificate) as Data).write(
          to: profile.file("fixture-cert.der"))
        try configure(UUID(), server.port)
        XCTAssertThrowsError(try DevelopmentRecoveryFixture.load(profile: profile))
        try configure(profile.id, 443)
        XCTAssertThrowsError(try DevelopmentRecoveryFixture.load(profile: profile))
        try configure(profile.id, server.port)
        let fixture = try XCTUnwrap(DevelopmentRecoveryFixture.load(profile: profile))
        let owner = try BrowserOwner(agentID: "test", projectPath: "/fixture", sessionID: "session")
        let payload = SensitivePayload(
          login: try StoredLogin(username: "fixture-user", password: "synthetic-password-42!"))
        let item = CredentialMetadata(
          id: profile.id, label: "QA", service: "Test", kind: .login,
          loginURL: fixture.loginURL, payloadRevision: payload.revision)
        let browser = try fixture.browser(credential: item, owner: owner)
        defer { browser.close() }
        try await browser.prepare()
        let page = try await browser.signIn(payload: payload)
        XCTAssertEqual(page.status, "recoveryCodeRequired")
        let other = try BrowserFixture()
        try (SecCertificateCopyData(other.certificate) as Data).write(
          to: profile.file("fixture-cert.der"))
        let wrong = try XCTUnwrap(DevelopmentRecoveryFixture.load(profile: profile))
        let rejected = try wrong.browser(credential: item, owner: owner)
        defer { rejected.close() }
        do {
          try await rejected.prepare()
          XCTFail("A valid but different fixture certificate must not be trusted")
        } catch {}
        XCTAssertEqual(rejected.lease.phase, .closed)
      }
    #endif

    private func recoveryItem(_ fixture: BrowserFixture, suffix: String = "") throws -> (
      CredentialMetadata, SensitivePayload
    ) {
      let payload = SensitivePayload(
        recoveryCodes: try RecoveryCodeSet(text: "fixture-recovery-001\nfixture-recovery-002"))
      return (
        CredentialMetadata(
          label: "Synthetic recovery", service: "Test", kind: .recoveryCodes,
          submissionURL: "https://127.0.0.1:\(fixture.port)/recover\(suffix)",
          payloadRevision: payload.revision), payload
      )
    }

    @MainActor func testRecoveryChallengeIsFixedAndCodeIsReservedBeforeSuccessfulSubmission()
      async throws
    {
      let fixture = try BrowserFixture()
      let (browser, login) = try fixture.browser(path: "/login-recovery")
      defer { browser.close() }
      let (item, codes) = try recoveryItem(fixture)
      try await browser.prepare()
      let challenge = try await browser.signIn(payload: login)
      XCTAssertEqual(challenge.status, "recoveryCodeRequired")
      XCTAssertTrue(challenge.links.isEmpty)
      XCTAssertFalse(challenge.text.contains("CHALLENGE_PRIVATE_TEXT"))
      let reread = try await browser.read()
      XCTAssertEqual(challenge, reread)
      _ = try browser.prepareRecovery(credential: item)
      do {
        _ = try await browser.read()
        XCTFail("Must not observe a pending recovery")
      } catch {}
      var saved: Data?
      let page = try await browser.recover(credential: item, payload: codes) { data in
        XCTAssertFalse(
          FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("cross-origin-request.recovery").path))
        saved = data
      }
      XCTAssertEqual(page.status, "pageReady")
      XCTAssertTrue(page.text.contains("Recovery verified"))
      let serialized = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
      for value in [
        "fixture-recovery-001", "verified-cookie", "fixture-user", "synthetic-password-42!",
        "private-recovery-csrf",
      ] {
        for variant in SecretRedactor.candidates(for: Data(value.utf8)) {
          XCTAssertFalse(serialized.contains(variant))
        }
      }
      let persisted = try SensitivePayload.decode(XCTUnwrap(saved), kind: .recoveryCodes)
      XCTAssertEqual(persisted.recoveryCodes?.entries.map(\.status), [.issued, .available])
      XCTAssertEqual(
        try String(
          contentsOf: fixture.directory.appendingPathComponent("cross-origin-request.recovery"),
          encoding: .utf8), "1")
      XCTAssertThrowsError(try browser.prepareRecovery(credential: item))
      let read = try await browser.read()
      XCTAssertTrue(read.text.contains("Recovery verified"))
    }

    @MainActor func testRecoverySaveFailureStaleRevisionAndRevocationPreventAnyPost() async throws {
      let fixture = try BrowserFixture()
      for mode in ["save", "stale", "close", "swap"] {
        let (browser, login) = try fixture.browser(path: "/login-recovery")
        defer { browser.close() }
        let (item, payload) = try recoveryItem(fixture)
        try await browser.prepare()
        _ = try await browser.signIn(payload: login)
        var wrong = item
        wrong.submissionURL = "https://elsewhere.invalid/recover"
        XCTAssertThrowsError(try browser.prepareRecovery(credential: wrong))
        XCTAssertEqual(browser.lease.phase, .recoveryRequired)
        _ = try browser.prepareRecovery(credential: item)
        var codes = payload
        var selected = item
        if mode == "stale" { codes.revision = UUID() }
        if mode == "swap" {
          selected = CredentialMetadata(
            label: item.label, service: item.service, kind: item.kind,
            submissionURL: item.submissionURL, payloadRevision: item.payloadRevision,
            createdAt: item.createdAt, updatedAt: item.updatedAt)
        }
        if mode == "close" { browser.close() }
        do {
          _ = try await browser.recover(credential: selected, payload: codes) { _ in
            XCTAssertEqual(mode, "save", "Stale/closed operations must not reserve")
            throw SensitiveDataError.invalidPayload
          }
          XCTFail("Must not submit")
        } catch {}
        XCTAssertEqual(browser.lease.phase, .closed)
      }
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: fixture.directory.appendingPathComponent("cross-origin-request.recovery").path))
    }

    @MainActor func testUnsupportedRecoveryFormsDoNotExposeChallengeContent() async throws {
      let fixture = try BrowserFixture()
      for suffix in ["-cross", "-extra"] {
        let (browser, login) = try fixture.browser(path: "/login-recovery\(suffix)")
        try await browser.prepare()
        do {
          _ = try await browser.signIn(payload: login)
          XCTFail("Unsupported challenge")
        } catch {}
        XCTAssertEqual(browser.lease.phase, .closed)
      }
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: fixture.directory.appendingPathComponent("cross-origin-request.recovery").path))
    }

    @MainActor func testSameURLPostRedirectsNeverResubmitLoginOrRecovery() async throws {
      for status in [307, 308] {
        for recovery in [false, true] {
          let fixture = try BrowserFixture()
          let path = recovery ? "/login-recovery-\(status)" : "/login-\(status)"
          let (browser, login) = try fixture.browser(path: path)
          defer { browser.close() }
          try await browser.prepare()
          var saved: Data?
          do {
            if recovery {
              _ = try await browser.signIn(payload: login)
              let (item, payload) = try recoveryItem(fixture, suffix: "-\(status)")
              _ = try browser.prepareRecovery(credential: item)
              _ = try await browser.recover(credential: item, payload: payload) { saved = $0 }
            } else {
              _ = try await browser.signIn(payload: login)
            }
            XCTFail("A repeated POST must fail")
          } catch {
            XCTAssertEqual(error as? ControlledBrowserError, .failed)
            for value in ["fixture-user", "synthetic-password-42!", "fixture-recovery-001"] {
              for variant in SecretRedactor.candidates(for: Data(value.utf8)) {
                XCTAssertFalse(error.localizedDescription.contains(variant))
              }
            }
          }
          XCTAssertEqual(browser.lease.phase, .closed)
          let marker = "cross-origin-request" + (recovery ? ".recovery" : ".post")
          XCTAssertEqual(
            try String(contentsOf: fixture.directory.appendingPathComponent(marker), encoding: .utf8),
            "1")
          if recovery {
            let payload = try SensitivePayload.decode(XCTUnwrap(saved), kind: .recoveryCodes)
            XCTAssertEqual(payload.recoveryCodes?.entries.map(\.status), [.issued, .available])
          }
        }
      }
    }

    @MainActor func testFailedRecoveryAndCrossOriginRedirectKeepReservationWithoutRetry()
      async throws
    {
      for suffix in ["-fail", "-redirect"] {
        let fixture = try BrowserFixture()
        let (browser, login) = try fixture.browser(path: "/login-recovery\(suffix)")
        let (item, codes) = try recoveryItem(fixture, suffix: suffix)
        try await browser.prepare()
        _ = try await browser.signIn(payload: login)
        _ = try browser.prepareRecovery(credential: item)
        var saved: Data?
        do {
          _ = try await browser.recover(credential: item, payload: codes) { saved = $0 }
          XCTFail("Must fail closed")
        } catch {}
        XCTAssertEqual(browser.lease.phase, .closed)
        let persisted = try SensitivePayload.decode(XCTUnwrap(saved), kind: .recoveryCodes)
        XCTAssertEqual(persisted.recoveryCodes?.entries.map(\.status), [.issued, .available])
        XCTAssertEqual(
          try String(
            contentsOf: fixture.directory.appendingPathComponent("cross-origin-request.recovery"),
            encoding: .utf8), "1")
        XCTAssertFalse(
          FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("cross-origin-request").path))
      }
    }

    @MainActor func testRecoveryInFlightCannotBeReadOrReopenedAfterClose() async throws {
      let fixture = try BrowserFixture()
      let (browser, login) = try fixture.browser(path: "/login-recovery-slow")
      let (item, codes) = try recoveryItem(fixture, suffix: "-slow")
      try await browser.prepare()
      _ = try await browser.signIn(payload: login)
      _ = try browser.prepareRecovery(credential: item)
      var saved: Data?
      let pending = Task {
        try await browser.recover(credential: item, payload: codes) { saved = $0 }
      }
      let marker = fixture.directory.appendingPathComponent("cross-origin-request.recovery")
      let deadline = Date().addingTimeInterval(5)
      while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
      do {
        _ = try await browser.read()
        XCTFail("Must not read a submitted code")
      } catch {}
      browser.close()
      do {
        _ = try await pending.value
        XCTFail("Close wins over the late response")
      } catch {}
      XCTAssertEqual(browser.lease.phase, .closed)
      let persisted = try SensitivePayload.decode(XCTUnwrap(saved), kind: .recoveryCodes)
      XCTAssertEqual(persisted.recoveryCodes?.entries.map(\.status), [.issued, .available])
    }

    @MainActor func testProductionTLSRejectsUntrustedCertificate() async throws {
      let fixture = try BrowserFixture()
      let (prepared, _) = try fixture.browser()
      defer { prepared.close() }
      let browser = try ControlledBrowserSession(
        credential: prepared.credential, owner: prepared.lease.owner)
      do {
        try await browser.prepare()
        XCTFail("Production must not trust the fixture certificate")
      } catch {}
      XCTAssertEqual(browser.lease.phase, .closed)
    }

    @MainActor func testRevocationAndStalePayloadPreventSubmission() async throws {
      let fixture = try BrowserFixture()
      for revoke in [false, true] {
        let (browser, payload) = try fixture.browser()
        try await browser.prepare()
        var changed = payload
        if revoke { browser.close() } else { changed.revision = UUID() }
        do {
          _ = try await browser.signIn(payload: changed)
          XCTFail("Must not submit")
        } catch {}
        XCTAssertEqual(browser.lease.phase, .closed)
      }
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath:
            fixture.directory.appendingPathComponent("cross-origin-request.post").path))
    }

    @MainActor func testRealWebKitLoginReadFollowAndClose() async throws {
      let fixture = try BrowserFixture()
      let (browser, payload) = try fixture.browser()
      defer { browser.close() }
      try await browser.prepare()
      XCTAssertEqual(browser.lease.phase, .awaitingApproval)
      do {
        _ = try await browser.read()
        XCTFail("Pre-approval read must fail")
      } catch {}
      let page = try await browser.signIn(payload: payload)
      XCTAssertEqual(page.status, "pageReady")
      XCTAssertTrue(page.text.contains("7 open issues"))
      XCTAssertFalse(page.text.contains("PAGE_SCRIPT_EXECUTED"))
      XCTAssertFalse(page.text.contains("private-value"))
      XCTAssertEqual(page.links.count, 1)
      let encoded = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
      XCTAssertFalse(encoded.contains("fixture-session-cookie"))
      XCTAssertFalse(encoded.contains("synthetic-password"))
      let link = try XCTUnwrap(page.links.first)
      let target = try browser.destination(for: link.id)
      let next = try await browser.follow(linkID: link.id, approvedURL: target)
      XCTAssertTrue(next.text.contains("7 open issues"))
      XCTAssertThrowsError(try browser.destination(for: link.id))
      browser.close()
      do {
        _ = try await browser.read()
        XCTFail("Closed browser must not read")
      } catch {}
    }

    @MainActor func testPageAndLinkTextExcludeInvisibleAndBlockedDescendants() async throws {
      let fixture = try BrowserFixture()
      let (browser, payload) = try fixture.browser()
      defer { browser.close() }
      try await browser.prepare()
      let page = try await browser.signIn(payload: payload)
      XCTAssertTrue(page.text.contains("7 open issues"))
      XCTAssertTrue(page.text.contains("Read details"))
      XCTAssertEqual(page.links.map(\.text), ["Read details"])
      let encoded = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
      for marker in [
        "hidden-link", "script-link", "textarea-link", "display-link", "visibility-link",
        "collapse-link", "visibility-body", "collapse-body",
      ] {
        XCTAssertFalse(encoded.contains(marker + "-private-value"), marker)
      }
    }

    @MainActor func testUnsupportedFormsFailBeforeAnySecretRelease() async throws {
      let fixture = try BrowserFixture()
      for path in ["/login-get", "/login-cross", "/login-otp"] {
        let (browser, _) = try fixture.browser(path: path)
        do {
          try await browser.prepare()
          XCTFail("Unsupported form: \(path)")
        } catch {}
        XCTAssertEqual(browser.lease.phase, .closed)
      }
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath:
            fixture.directory.appendingPathComponent("cross-origin-request").path))
    }

    @MainActor func testFailureAndCrossOriginRedirectDestroyPrivateSession() async throws {
      let fixture = try BrowserFixture()
      for path in ["/login-fail", "/login-redirect"] {
        let (browser, payload) = try fixture.browser(path: path)
        try await browser.prepare()
        do {
          _ = try await browser.signIn(payload: payload)
          XCTFail("Must fail closed: \(path)")
        } catch {}
        XCTAssertEqual(browser.lease.phase, .closed)
      }
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath:
            fixture.directory.appendingPathComponent("cross-origin-request").path))
    }

    @MainActor func testReflectedSecretsAreNotInPageResults() async throws {
      let fixture = try BrowserFixture()
      let (browser, payload) = try fixture.browser(path: "/login-reflect")
      defer { browser.close() }
      try await browser.prepare()
      let page = try await browser.signIn(payload: payload)
      let json = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
      XCTAssertFalse(json.contains(payload.login!.username))
      XCTAssertFalse(json.contains(payload.login!.password))
      XCTAssertFalse(json.contains(Data(payload.login!.password.utf8).base64EncodedString()))
      XCTAssertFalse(json.contains("fixture-session-cookie"))
    }

    @MainActor func testConcurrentReadAndRevocationDuringSubmission() async throws {
      let fixture = try BrowserFixture()
      let (browser, payload) = try fixture.browser(path: "/login-slow")
      try await browser.prepare()
      let pending = Task { try await browser.signIn(payload: payload) }
      try await Task.sleep(for: .milliseconds(200))
      do {
        _ = try await browser.read()
        XCTFail("Must not read during sign-in")
      } catch {}
      browser.close()
      do {
        _ = try await pending.value
        XCTFail("Revocation must win")
      } catch {}
      XCTAssertEqual(browser.lease.phase, .closed)
    }

    @MainActor func testRevocationDuringReadDiscardsLatePage() async throws {
      let fixture = try BrowserFixture()
      let (browser, payload) = try fixture.browser()
      defer { browser.close() }
      try await browser.prepare()
      _ = try await browser.signIn(payload: payload)
      let pending = Task { try await browser.read() }
      let deadline = Date().addingTimeInterval(5)
      while browser.lease.phase == .ready, Date() < deadline { await Task.yield() }
      XCTAssertEqual(browser.lease.phase, .reading)
      browser.close()
      do {
        _ = try await pending.value
        XCTFail("A revoked read must not return a page")
      } catch {}
      XCTAssertEqual(browser.lease.phase, .closed)
    }

    @MainActor func testRevocationDuringFollowDiscardsLatePageAndClosesOnce() async throws {
      let fixture = try BrowserFixture()
      let (browser, payload) = try fixture.browser(path: "/login-slow-follow")
      defer { browser.close() }
      var closures = 0
      browser.onClose = { closures += 1 }
      try await browser.prepare()
      let page = try await browser.signIn(payload: payload)
      let link = try XCTUnwrap(page.links.first)
      let destination = try browser.destination(for: link.id)
      let pending = Task { try await browser.follow(linkID: link.id, approvedURL: destination) }
      let marker = fixture.directory.appendingPathComponent("cross-origin-request.follow")
      let deadline = Date().addingTimeInterval(5)
      while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
      do {
        _ = try await browser.read()
        XCTFail("No observations during navigation")
      } catch {}
      browser.close()
      do {
        _ = try await pending.value
        XCTFail("A revoked navigation must not return a page")
      } catch {}
      browser.close()
      XCTAssertEqual(closures, 1)
      XCTAssertEqual(browser.lease.phase, .closed)
      do {
        _ = try await browser.read()
        XCTFail("A late callback must not reopen the browser")
      } catch {}
    }
  }
#endif
