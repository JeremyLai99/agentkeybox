import XCTest

@testable import AgentKeyBoxCore

final class AgentKeyBoxCoreTests: XCTestCase {
  func testInMemorySecretStoreRoundTrip() throws {
    let store = InMemorySecretStore()
    let id = UUID()
    let secret = Data("sk-test-secret".utf8)

    try store.save(secret: secret, id: id)
    XCTAssertEqual(try store.read(id: id), secret)

    try store.delete(id: id)
    XCTAssertNil(try store.read(id: id))
  }

  func testEnvParser() {
    let parsed = EnvParser.parse(
      """
      # comment
      OPENAI_API_KEY=sk-test
      export STRIPE_SECRET_KEY="sk_stripe"
      EMPTY=
      """)

    XCTAssertEqual(parsed["OPENAI_API_KEY"], "sk-test")
    XCTAssertEqual(parsed["STRIPE_SECRET_KEY"], "sk_stripe")
    XCTAssertEqual(parsed["EMPTY"], "")
  }

  func testApprovalEngineSessionApprovalIsScoped() async {
    let engine = ApprovalEngine()
    let request = AgentRequest(
      agentID: "claude-code",
      agentDisplayName: "Claude Code",
      projectPath: "/tmp/project-a",
      credentialIdentifier: "credential-1",
      requestedScope: .session,
      sessionID: "session-1"
    )

    await engine.record(
      decision: .allowSession,
      request: request,
      credentialLabel: "OpenAI"
    )

    let same = await engine.preauthorizedDecision(for: request)
    XCTAssertEqual(same, .allowSession)

    var otherSession = request
    otherSession.sessionID = "session-2"
    let different = await engine.preauthorizedDecision(for: otherSession)
    XCTAssertNil(different)
  }

  func testApprovalHistoryNeverContainsSecretMaterial() async {
    let engine = ApprovalEngine()
    let request = AgentRequest(
      agentID: "codex",
      agentDisplayName: "Codex",
      projectPath: "/tmp/project",
      credentialIdentifier: "credential-id",
      purpose: "Call Stripe"
    )

    await engine.record(
      decision: .allowOnce, request: request, credentialLabel: "Stripe Production")
    let history = await engine.history()

    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history[0].credentialLabel, "Stripe Production")
    XCTAssertEqual(history[0].decision, .allowOnce)
  }

  func testBrokerRequestRoundTrip() throws {
    let request = BrokerRequest(
      authToken: "test-token",
      action: .executeWithSecret,
      agentID: "codex",
      agentDisplayName: "Codex",
      projectPath: "/tmp/project",
      credentialIdentifier: UUID().uuidString,
      purpose: "Run integration test",
      executablePath: "/usr/bin/curl",
      arguments: ["https://example.com"],
      environmentVariable: "API_KEY",
      requestedScope: .once,
      sessionID: "session-test"
    )

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(BrokerRequest.self, from: data)
    XCTAssertEqual(decoded.action, .executeWithSecret)
    XCTAssertEqual(decoded.agentID, "codex")
    XCTAssertEqual(decoded.executablePath, "/usr/bin/curl")
    XCTAssertEqual(decoded.arguments, ["https://example.com"])
    XCTAssertEqual(decoded.environmentVariable, "API_KEY")
  }

  func testMetadataStorePersistsOnlyMetadata() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentKeyBoxTests-\(UUID().uuidString)")
      .appendingPathComponent("metadata.json")
    let store = MetadataStore(fileURL: url)
    let project = Project(name: "Demo", rootPath: "/tmp/demo")
    let credential = CredentialMetadata(
      label: "Stripe Production",
      service: "Stripe",
      projectID: project.id,
      environment: "production"
    )
    try store.save(MetadataSnapshot(projects: [project], credentials: [credential]))

    let loaded = store.load()
    XCTAssertEqual(loaded.projects, [project])
    XCTAssertEqual(loaded.credentials, [credential])

    let raw = try String(contentsOf: url, encoding: .utf8)
    XCTAssertFalse(raw.contains("sk_"))
    XCTAssertFalse(raw.contains("secretBase64"))
  }

  func testBrokerTokenStoreCreatesAndReloadsToken() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentKeyBoxTokenTests-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("broker-token")
    let store = BrokerTokenStore(fileURL: url)

    let first = try store.loadOrCreate()
    let second = try store.load()

    XCTAssertEqual(first, second)
    XCTAssertGreaterThanOrEqual(first.count, 32)
  }

  func testSecretRedactorRemovesRawAndEncodedSecret() {
    let secret = Data("super-secret-value".utf8)
    let base64 = secret.base64EncodedString()
    let hex = secret.map { String(format: "%02x", $0) }.joined()
    let text = "raw=super-secret-value base64=\(base64) hex=\(hex)"

    let redacted = SecretRedactor.redact(text, secretData: secret)

    XCTAssertFalse(redacted.contains("super-secret-value"))
    XCTAssertFalse(redacted.contains(base64))
    XCTAssertFalse(redacted.contains(hex))
    XCTAssertTrue(redacted.contains("[REDACTED_BY_AGENTKEYBOX]"))
  }

  func testApprovedCommandRunnerInjectsAndRedactsSecret() throws {
    #if os(Linux) || os(macOS)
      let secret = Data("runner-secret-123".utf8)
      let temp = FileManager.default.temporaryDirectory
      let result = try ApprovedCommandRunner.run(
        executablePath: "/usr/bin/env",
        arguments: [],
        workingDirectory: temp.path,
        environmentVariable: "AGENTKEYBOX_TEST_SECRET",
        secretData: secret,
        maxOutputBytes: 128 * 1024
      )

      XCTAssertEqual(result.exitCode, 0)
      XCTAssertFalse(result.output.contains("runner-secret-123"))
      XCTAssertTrue(result.output.contains("AGENTKEYBOX_TEST_SECRET=[REDACTED_BY_AGENTKEYBOX]"))
    #endif
  }
  func testEnvParserSupportsCommentsEscapesAndMultilineQuotes() {
    let parsed = EnvParser.parse(
      """
      A=value # comment
      B="line1\nline2"
      C="first
      second"
      D='literal\ntext'
      INVALID-KEY=nope
      """)

    XCTAssertEqual(parsed["A"], "value")
    XCTAssertEqual(parsed["B"], "line1\nline2")
    XCTAssertEqual(parsed["C"], "first\nsecond")
    XCTAssertEqual(parsed["D"], "literal\ntext")
    XCTAssertNil(parsed["INVALID-KEY"])
  }

  func testProviderCatalogInfersCommonServices() {
    XCTAssertEqual(ProviderCatalog.inferService(fromEnvironmentKey: "OPENAI_API_KEY"), "OpenAI")
    XCTAssertEqual(
      ProviderCatalog.inferService(fromEnvironmentKey: "SUPABASE_SERVICE_ROLE_KEY"), "Supabase")
    XCTAssertEqual(
      ProviderCatalog.inferService(fromEnvironmentKey: "GEMINI_API_KEY"), "Google / Gemini")
  }

  func testProjectScopeResolverPreventsPrefixConfusion() {
    let project = Project(name: "A", rootPath: "/tmp/project")
    let credential = CredentialMetadata(label: "Key", service: "Test", projectID: project.id)

    XCTAssertTrue(
      ProjectScopeResolver.isVisible(credential, projects: [project], requestPath: "/tmp/project"))
    XCTAssertTrue(
      ProjectScopeResolver.isVisible(
        credential, projects: [project], requestPath: "/tmp/project/subdir"))
    XCTAssertFalse(
      ProjectScopeResolver.isVisible(
        credential, projects: [project], requestPath: "/tmp/project-other"))
  }

  func testGlobalCredentialIsVisibleAcrossProjects() {
    let credential = CredentialMetadata(label: "Global", service: "Test")
    XCTAssertTrue(
      ProjectScopeResolver.isVisible(credential, projects: [], requestPath: "/tmp/anything"))
  }

  func testBrokerReplayGuardRejectsReplayAndExpiredRequests() async {
    let guarder = BrokerReplayGuard(freshnessWindow: 60)
    let now = Date()
    let request = BrokerRequest(
      requestID: UUID(),
      issuedAt: now,
      action: .listCredentials,
      agentID: "test",
      agentDisplayName: "Test",
      projectPath: "/tmp"
    )

    let firstAccepted = await guarder.accept(request, now: now)
    let replayAccepted = await guarder.accept(request, now: now)
    XCTAssertTrue(firstAccepted)
    XCTAssertFalse(replayAccepted)

    let expired = BrokerRequest(
      issuedAt: now.addingTimeInterval(-120),
      action: .listCredentials,
      agentID: "test",
      agentDisplayName: "Test",
      projectPath: "/tmp"
    )
    let expiredAccepted = await guarder.accept(expired, now: now)
    XCTAssertFalse(expiredAccepted)
  }

  func testCommandRiskAnalyzerFlagsNetworkAndInterpreters() {
    XCTAssertEqual(
      CommandRiskAnalyzer.assess(
        executablePath: "/usr/bin/curl", arguments: ["https://example.com"]
      ).level, .high)
    XCTAssertEqual(
      CommandRiskAnalyzer.assess(executablePath: "/usr/bin/python3", arguments: ["script.py"])
        .level, .high)
    XCTAssertEqual(
      CommandRiskAnalyzer.assess(executablePath: "/usr/bin/true", arguments: []).level, .normal)
  }

  func testApprovedCommandRunnerTemporaryFileDeliveryCleansUp() throws {
    #if os(Linux) || os(macOS)
      let result = try ApprovedCommandRunner.run(
        executablePath: "/usr/bin/env",
        arguments: [],
        workingDirectory: FileManager.default.temporaryDirectory.path,
        environmentVariable: "AGENTKEYBOX_SECRET_FILE",
        secretData: Data("file-secret".utf8),
        deliveryMode: .tempFile
      )
      guard
        let line = result.output.split(separator: "\n").first(where: {
          $0.hasPrefix("AGENTKEYBOX_SECRET_FILE=")
        })
      else {
        return XCTFail("Expected temporary-file environment variable in output")
      }
      let path = String(line.dropFirst("AGENTKEYBOX_SECRET_FILE=".count))
      XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    #endif
  }

  func testApprovedCommandRunnerRejectsBinaryEnvironmentSecret() throws {
    #if os(Linux) || os(macOS)
      XCTAssertThrowsError(
        try ApprovedCommandRunner.run(
          executablePath: "/usr/bin/env",
          arguments: [],
          workingDirectory: FileManager.default.temporaryDirectory.path,
          environmentVariable: "AGENTKEYBOX_BINARY",
          secretData: Data([0xFF, 0xFE]),
          deliveryMode: .environment
        )
      ) { error in
        XCTAssertEqual(error as? CommandRunnerError, .secretNotUTF8)
      }
    #endif
  }

  func testEnvironmentVariableValidation() {
    XCTAssertTrue(ApprovedCommandRunner.isValidEnvironmentVariable("OPENAI_API_KEY"))
    XCTAssertTrue(ApprovedCommandRunner.isValidEnvironmentVariable("_PRIVATE"))
    XCTAssertFalse(ApprovedCommandRunner.isValidEnvironmentVariable("9INVALID"))
    XCTAssertFalse(ApprovedCommandRunner.isValidEnvironmentVariable("BAD-NAME"))
  }

  func testSessionApprovalIsBoundToOperationAndDelivery() async {
    let engine = ApprovalEngine()
    let base = AgentRequest(
      agentID: "claude-code",
      agentDisplayName: "Claude Code",
      projectPath: "/tmp/project",
      credentialIdentifier: "credential",
      operation: "/usr/bin/true",
      executablePath: "/usr/bin/true",
      arguments: [],
      environmentVariable: "API_KEY",
      deliveryMode: .environment,
      requestedScope: .session,
      sessionID: "s1"
    )
    await engine.record(decision: .allowSession, request: base, credentialLabel: "Demo")
    let baseDecision = await engine.preauthorizedDecision(for: base)
    XCTAssertEqual(baseDecision, .allowSession)

    var changedCommand = base
    changedCommand.operation = "/usr/bin/env"
    changedCommand.executablePath = "/usr/bin/env"
    let changedDecision = await engine.preauthorizedDecision(for: changedCommand)
    XCTAssertNil(changedDecision)

    var changedArguments = base
    changedArguments.arguments = ["--version"]
    let argumentsDecision = await engine.preauthorizedDecision(for: changedArguments)
    XCTAssertNil(argumentsDecision)

    var changedDelivery = base
    changedDelivery.deliveryMode = .tempFile
    let deliveryDecision = await engine.preauthorizedDecision(for: changedDelivery)
    XCTAssertNil(deliveryDecision)
  }

  func testApprovedCommandRunnerTimesOut() throws {
    #if os(Linux) || os(macOS)
      let sleepPath =
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sleep")
        ? "/usr/bin/sleep" : "/bin/sleep"
      XCTAssertThrowsError(
        try ApprovedCommandRunner.run(
          executablePath: sleepPath,
          arguments: ["2"],
          workingDirectory: FileManager.default.temporaryDirectory.path,
          environmentVariable: "AGENTKEYBOX_TIMEOUT_SECRET",
          secretData: Data("secret".utf8),
          timeoutSeconds: 0.05
        )
      ) { error in
        XCTAssertEqual(error as? CommandRunnerError, .executionTimedOut)
      }
    #endif
  }

  func testMetadataAndBrokerTokenFilesUseOwnerOnlyPermissionsWhenSupported() throws {
    #if os(Linux) || os(macOS)
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "AgentKeyBoxPerms-\(UUID().uuidString)")
      let metadataURL = root.appendingPathComponent("metadata.json")
      let tokenURL = root.appendingPathComponent("broker-token")

      let metadataStore = MetadataStore(fileURL: metadataURL)
      try metadataStore.save(MetadataSnapshot())
      let tokenStore = BrokerTokenStore(fileURL: tokenURL)
      _ = try tokenStore.loadOrCreate()

      let metadataAttrs = try FileManager.default.attributesOfItem(atPath: metadataURL.path)
      let tokenAttrs = try FileManager.default.attributesOfItem(atPath: tokenURL.path)
      let metadataPerms = (metadataAttrs[.posixPermissions] as? NSNumber)?.intValue
      let tokenPerms = (tokenAttrs[.posixPermissions] as? NSNumber)?.intValue
      XCTAssertEqual(metadataPerms, 0o600)
      XCTAssertEqual(tokenPerms, 0o600)
    #endif
  }

  func testSecretRedactorRemovesJSONEscapedSecret() {
    let secretText = "line1\nline2\"quoted\""
    let data = Data(secretText.utf8)
    let encoded = try! JSONEncoder().encode(secretText)
    let jsonEscaped = String(data: encoded, encoding: .utf8)!.dropFirst().dropLast()
    let result = SecretRedactor.redact("payload=\(jsonEscaped)", secretData: data)
    XCTAssertFalse(result.contains(jsonEscaped))
    XCTAssertTrue(result.contains("[REDACTED_BY_AGENTKEYBOX]"))
  }

  func testAgentIntegrationCommandCaptureHandlesLargeOutput() throws {
    #if os(Linux) || os(macOS)
      let shell =
        FileManager.default.isExecutableFile(atPath: "/bin/sh") ? "/bin/sh" : "/usr/bin/sh"
      let output = try runExecutable(
        shell,
        arguments: [
          "-c",
          "i=0; while [ $i -lt 5000 ]; do printf abcdefghijklmnopqrstuvwxyz; i=$((i+1)); done",
        ]
      )
      XCTAssertGreaterThan(output.utf8.count, 100_000)
      XCTAssertLessThanOrEqual(output.utf8.count, 256 * 1024)
    #endif
  }

  // MARK: - http_request policy

  private func validate(
    url: String = "https://api.stripe.com/v1/charges",
    method: String = "GET",
    headers: [String: String] = ["Authorization": "Bearer {{secret}}"],
    body: String? = nil,
    allowedHosts: [String]? = ["api.stripe.com"]
  ) throws -> ValidatedHTTPRequest {
    try HTTPRequestPolicy.validate(
      method: method, url: url, headers: headers, body: body, allowedHosts: allowedHosts)
  }

  func testHTTPPolicyAcceptsAllowedHostRequest() throws {
    let request = try validate(method: "post")
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.host, "api.stripe.com")
    XCTAssertTrue(request.hostRestricted)
  }

  func testHTTPPolicyRejectsUnsafeRequests() {
    XCTAssertThrowsError(try validate(url: "http://api.stripe.com/v1")) {
      XCTAssertEqual($0 as? HTTPRequestPolicyError, .httpsRequired)
    }
    XCTAssertThrowsError(try validate(url: "https://evil.example/collect")) {
      XCTAssertEqual(
        $0 as? HTTPRequestPolicyError,
        .hostNotAllowed(host: "evil.example", allowed: ["api.stripe.com"]))
    }
    XCTAssertThrowsError(try validate(url: "https://api.stripe.com/v1?key={{secret}}")) {
      XCTAssertEqual($0 as? HTTPRequestPolicyError, .placeholderOutsideHeaders)
    }
    XCTAssertThrowsError(try validate(body: "token={{secret}}")) {
      XCTAssertEqual($0 as? HTTPRequestPolicyError, .placeholderOutsideHeaders)
    }
    XCTAssertThrowsError(try validate(headers: ["Accept": "application/json"])) {
      XCTAssertEqual($0 as? HTTPRequestPolicyError, .placeholderMissing)
    }
    XCTAssertThrowsError(
      try validate(headers: ["Authorization": "Bearer {{secret}}", "Host": "evil.example"])
    ) {
      XCTAssertEqual($0 as? HTTPRequestPolicyError, .forbiddenHeader("Host"))
    }
    XCTAssertThrowsError(try validate(url: "https://user:pw@api.stripe.com/")) {
      XCTAssertEqual($0 as? HTTPRequestPolicyError, .credentialsInURL)
    }
    XCTAssertThrowsError(try validate(method: "TRACE")) {
      XCTAssertEqual($0 as? HTTPRequestPolicyError, .unsupportedMethod("TRACE"))
    }
  }

  func testHTTPPolicyUnrestrictedCredentialIsFlagged() throws {
    let request = try validate(url: "https://example.com/api", allowedHosts: nil)
    XCTAssertFalse(request.hostRestricted)
  }

  func testHostWildcardDoesNotMatchLookalikes() {
    XCTAssertTrue(HTTPRequestPolicy.hostMatches("abc.supabase.co", pattern: "*.supabase.co"))
    XCTAssertTrue(HTTPRequestPolicy.hostMatches("API.Stripe.com", pattern: "api.stripe.com"))
    XCTAssertFalse(HTTPRequestPolicy.hostMatches("supabase.co", pattern: "*.supabase.co"))
    XCTAssertFalse(HTTPRequestPolicy.hostMatches("evilsupabase.co", pattern: "*.supabase.co"))
    XCTAssertFalse(HTTPRequestPolicy.hostMatches("api.stripe.com.evil.io", pattern: "api.stripe.com"))
  }

  func testRedactThenTruncateNeverLeaksSecretPrefixAtBoundary() {
    let secret = "sk_test_ABCDEFGHIJKLMNOP"
    // The secret starts 10 bytes before the visible limit, so truncating first would leak
    // "sk_test_AB".
    let text = String(repeating: "x", count: 90) + secret + String(repeating: "y", count: 50)
    let (visible, truncated) = SecretRedactor.redactThenTruncate(
      Data(text.utf8), secretData: Data(secret.utf8), maxBytes: 100)
    XCTAssertTrue(truncated)
    XCTAssertFalse(visible.contains("sk_test"))
  }

  func testCredentialMetadataDecodesSnapshotsWithoutNewFields() throws {
    let legacy = """
      {"id":"3BB35765-FD77-484F-99B2-E2181D934056","label":"DEMO_API_KEY","service":"Demo",
       "kind":"apiKey","createdAt":0,"updatedAt":0}
      """
    let metadata = try JSONDecoder().decode(CredentialMetadata.self, from: Data(legacy.utf8))
    XCTAssertNil(metadata.environmentVariableName)
    XCTAssertNil(metadata.allowedHosts)
    XCTAssertEqual(metadata.injectionVariableName, "DEMO_API_KEY")

    var labelled = metadata
    labelled.label = "Stripe Production"
    XCTAssertNil(labelled.injectionVariableName, "labels that are not variable names are ignored")
  }

  func testProviderPresetLookupPrefillsAllowlist() {
    let preset = ProviderCatalog.preset(matchingService: nil, environmentKey: "STRIPE_SECRET_KEY")
    XCTAssertEqual(preset?.allowedHosts, ["api.stripe.com"])
    XCTAssertNotNil(preset?.dashboardURL)
    XCTAssertEqual(
      ProviderCatalog.preset(matchingService: "openai", environmentKey: nil)?.id, "openai")
  }

  #if os(macOS)
    func testHTTPExecutorRedactsResponseAndRefusesRedirects() async throws {
      let server = try TinyHTTPServer()
      defer { server.stop() }
      let secret = "sk_test_echoed_secret_value"

      // The server echoes the Authorization header back; the executor must redact it.
      var echo = ValidatedHTTPRequest(
        method: "GET", url: URL(string: "http://127.0.0.1:\(server.port)/echo")!,
        host: "127.0.0.1", headers: ["Authorization": "Bearer {{secret}}"], body: nil,
        hostRestricted: true)
      let echoed = try await HTTPRequestExecutor.execute(echo, secretData: Data(secret.utf8))
      XCTAssertEqual(echoed.statusCode, 200)
      XCTAssertTrue(echoed.body.contains("[REDACTED_BY_AGENTKEYBOX]"))
      XCTAssertFalse(echoed.body.contains(secret))

      // A redirect is returned as-is instead of replaying the credential to the new location.
      echo.url = URL(string: "http://127.0.0.1:\(server.port)/redirect")!
      let redirected = try await HTTPRequestExecutor.execute(echo, secretData: Data(secret.utf8))
      XCTAssertEqual(redirected.statusCode, 302)
      XCTAssertEqual(server.requestedPaths, ["/echo", "/redirect"])
    }
  #endif

  func testExecutableSearchPathCoversFinderLaunchedApps() {
    // The PATH a Finder-launched app actually receives.
    let directories = ExecutableSearchPath.directories(
      environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/bin"])
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    XCTAssertEqual(directories.first, "/usr/bin")
    XCTAssertEqual(directories.count, Set(directories).count, "directories must be de-duplicated")
    for expected in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin"] {
      XCTAssertTrue(directories.contains(expected), "missing \(expected)")
    }
  }

  #if os(macOS)
    /// Short root so the socket path stays under the 103-byte `sun_path` limit.
    private func makeBrokerFixture() throws -> (root: URL, socket: URL, tokens: BrokerTokenStore) {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "akb-\(UUID().uuidString.prefix(8))")
      let tokens = BrokerTokenStore(fileURL: root.appendingPathComponent("broker-token"))
      _ = try tokens.loadOrCreate()
      return (root, root.appendingPathComponent("broker.sock"), tokens)
    }

    func testBrokerRoundTripOverOwnerOnlyUnixSocket() async throws {
      let fixture = try makeBrokerFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let server = LocalBrokerServer(
        socketURL: fixture.socket,
        expectedAuthToken: try fixture.tokens.load()
      ) { request in
        BrokerResponse(ok: true, decision: request.agentID == "test" ? .allowOnce : .deny)
      }
      try server.start()
      defer { server.stop() }
      try await Task.sleep(for: .milliseconds(200))

      let directoryPerms =
        (try FileManager.default.attributesOfItem(atPath: fixture.root.path)[.posixPermissions]
        as? NSNumber)?.intValue
      XCTAssertEqual(directoryPerms, 0o700)

      let client = LocalBrokerClient(
        socketURL: fixture.socket, tokenStore: fixture.tokens, timeoutSeconds: 5)
      let response = try await client.send(
        BrokerRequest(
          action: .listCredentials, agentID: "test", agentDisplayName: "Test", projectPath: "/tmp"))
      XCTAssertEqual(response.decision, .allowOnce)
    }

    func testBrokerRejectsWrongToken() async throws {
      let fixture = try makeBrokerFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let server = LocalBrokerServer(
        socketURL: fixture.socket,
        expectedAuthToken: String(repeating: "x", count: 44)
      ) { _ in BrokerResponse(ok: true) }
      try server.start()
      defer { server.stop() }
      try await Task.sleep(for: .milliseconds(200))

      let client = LocalBrokerClient(
        socketURL: fixture.socket, tokenStore: fixture.tokens, timeoutSeconds: 5)
      do {
        _ = try await client.send(
          BrokerRequest(
            action: .listCredentials, agentID: "test", agentDisplayName: "Test",
            projectPath: "/tmp"))
        XCTFail("Expected unauthorized request to fail")
      } catch {
        XCTAssertEqual(
          error as? BrokerError, .requestFailed("Unauthorized local broker request."))
      }
    }

    func testBrokerClientReportsAppNotRunningPromptly() async throws {
      let fixture = try makeBrokerFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }

      // A stale socket file with no listener must fail fast, not wait for the full timeout.
      FileManager.default.createFile(atPath: fixture.socket.path, contents: nil)
      for _ in 0..<2 {
        let client = LocalBrokerClient(
          socketURL: fixture.socket, tokenStore: fixture.tokens, timeoutSeconds: 30)
        let start = Date()
        do {
          _ = try await client.send(
            BrokerRequest(
              action: .listCredentials, agentID: "test", agentDisplayName: "Test",
              projectPath: "/tmp"))
          XCTFail("Expected missing broker to fail")
        } catch {
          XCTAssertEqual(error as? BrokerError, .appNotRunning)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        try? FileManager.default.removeItem(at: fixture.socket)
      }
    }
  #endif

}
