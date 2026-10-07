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
    XCTAssertEqual(request.hostStatus, .listed)
  }

  func testHTTPPolicyRejectsUnsafeRequests() {
    XCTAssertThrowsError(try validate(url: "http://api.stripe.com/v1")) {
      XCTAssertEqual($0 as? HTTPRequestPolicyError, .httpsRequired)
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
    XCTAssertEqual(request.hostStatus, .unrestricted)
  }

  func testHTTPPolicyLetsUserDecideOnUnlistedHost() throws {
    // Not rejected outright any more: the approval prompt warns and defaults to Deny.
    let request = try validate(url: "https://evil.example/collect")
    XCTAssertEqual(request.hostStatus, .unlisted(allowed: ["api.stripe.com"]))
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
        hostStatus: .listed)
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

  // MARK: - Review items 7, 15, 16

  func testRunnerRedactsSecretStraddlingOutputLimitAndBoundsMemory() throws {
    #if os(Linux) || os(macOS)
      let secret = "sk_test_STRADDLE_0123456789"
      // 95 filler bytes, then the secret across the 100-byte limit, then 2 MB of noise.
      let script =
        "printf '%095d' 0; printf %s \"$AKB_SECRET\"; head -c 2000000 /dev/zero | tr '\\0' y"
      let result = try ApprovedCommandRunner.run(
        executablePath: "/bin/sh",
        arguments: ["-c", script],
        workingDirectory: FileManager.default.temporaryDirectory.path,
        environmentVariable: "AKB_SECRET",
        secretData: Data(secret.utf8),
        maxOutputBytes: 100
      )
      XCTAssertTrue(result.outputTruncated)
      XCTAssertFalse(result.output.contains("sk_test"), "a secret prefix leaked at the limit")
      XCTAssertLessThan(result.output.utf8.count, 200)
    #endif
  }

  func testReservedVariablesCannotReceiveSecrets() {
    XCTAssertTrue(ApprovedCommandRunner.isAllowedInjectionTarget("STRIPE_SECRET_KEY"))
    for reserved in ["PATH", "home", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "NODE_OPTIONS", "LC_ALL"]
    {
      XCTAssertFalse(ApprovedCommandRunner.isAllowedInjectionTarget(reserved), reserved)
    }
    XCTAssertFalse(ApprovedCommandRunner.isValidEnvironmentVariable("ÅPI_KEY"), "ASCII only")
    XCTAssertThrowsError(
      try ApprovedCommandRunner.run(
        executablePath: "/usr/bin/true", arguments: [],
        workingDirectory: FileManager.default.temporaryDirectory.path,
        environmentVariable: "PATH", secretData: Data("x".utf8))
    ) { XCTAssertEqual($0 as? CommandRunnerError, .invalidEnvironmentVariable) }
  }

  func testRiskAnalyzerFlagsVersionedInterpretersAndProjectCode() {
    XCTAssertEqual(
      CommandRiskAnalyzer.assess(executablePath: "/usr/bin/python3.12", arguments: []).level, .high)
    XCTAssertEqual(
      CommandRiskAnalyzer.assess(executablePath: "/opt/homebrew/bin/bun", arguments: []).level,
      .high)
    XCTAssertEqual(
      CommandRiskAnalyzer.assess(executablePath: "/usr/bin/env", arguments: ["node"]).level, .high)
    XCTAssertEqual(
      CommandRiskAnalyzer.assess(executablePath: "/opt/homebrew/bin/npm", arguments: ["test"])
        .level, .elevated)

    let insideProject = CommandRiskAnalyzer.assess(
      executablePath: "/tmp/akb-project/scripts/deploy.sh", arguments: [],
      projectPath: "/tmp/akb-project")
    XCTAssertEqual(insideProject.level, .elevated)
    XCTAssertEqual(
      CommandRiskAnalyzer.assess(
        executablePath: "/usr/bin/true", arguments: [], projectPath: "/tmp/akb-project"
      ).level, .normal)
  }

  func testCorruptMetadataIsQuarantinedNotOverwritten() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AgentKeyBoxCorrupt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("metadata.json")
    let original = Data("{\"projects\": [ truncated".utf8)
    try original.write(to: fileURL)

    let store = MetadataStore(fileURL: fileURL)
    let (snapshot, quarantined) = store.loadWithRecovery()
    XCTAssertTrue(snapshot.projects.isEmpty)
    let backup = try XCTUnwrap(quarantined)
    XCTAssertEqual(try Data(contentsOf: backup), original)

    // Saving afterwards must leave the quarantined copy untouched.
    try store.save(MetadataSnapshot(projects: [Project(name: "new", rootPath: "/tmp/new")]))
    XCTAssertEqual(try Data(contentsOf: backup), original)
    XCTAssertEqual(store.load().projects.map(\.name), ["new"])
  }

  func testEnvImportClassifierSeparatesSecretsFromSettings() {
    let secrets = [
      ("STRIPE_SECRET_KEY", "sk_test_123"), ("OPENAI_API_KEY", "sk-abc"),
      ("GITHUB_TOKEN", "ghp_x"), ("DB_PASSWORD", "hunter2"), ("SENTRY_DSN", "https://x@o.io/1"),
      ("DATABASE_URL", "postgres://app:s3cret@db.example.com:5432/app"),
    ]
    for (key, value) in secrets {
      XCTAssertTrue(EnvImportClassifier.looksSecret(key: key, value: value), key)
    }
    let settings = [
      ("PORT", "3000"), ("NODE_ENV", "development"), ("DEBUG", "true"),
      ("DATABASE_URL", "postgres://localhost:5432/app"),
      ("NEXT_PUBLIC_SUPABASE_URL", "https://x.supabase.co"),
      ("STRIPE_PUBLISHABLE_KEY", "pk_test_123"), ("SUPABASE_ANON_KEY", "eyJ..."),
    ]
    for (key, value) in settings {
      XCTAssertFalse(EnvImportClassifier.looksSecret(key: key, value: value), key)
    }
  }

  func testCommandDisplayCannotHideOrMergeArguments() {
    let shown = CommandDisplay.lines(
      executable: "/usr/bin/curl",
      arguments: [
        "https://api.stripe.com", "\n\n\n-d @/etc/hosts", "two words", "", "evil\u{202E}txt.sh",
      ])
    XCTAssertEqual(
      shown.components(separatedBy: "\n"),
      [
        "/usr/bin/curl", "https://api.stripe.com", "\"\\n\\n\\n-d @/etc/hosts\"", "\"two words\"",
        "\"\"", "evil\\u{202e}txt.sh",
      ])
  }

  // MARK: - Approval presentation

  private func stripeCredential() -> CredentialMetadata {
    CredentialMetadata(
      label: "STRIPE_SECRET_KEY", service: "Stripe", environmentVariableName: "STRIPE_SECRET_KEY",
      allowedHosts: ["api.stripe.com"])
  }

  private func httpRequest(host: String, status: HTTPHostStatus) -> AgentRequest {
    var request = AgentRequest(
      agentID: "claude-code", agentDisplayName: "Claude Code", projectPath: "/tmp/demo",
      credentialIdentifier: UUID().uuidString, purpose: "Check the balance")
    request.kind = .httpRequest
    request.url = "https://\(host)/v1/balance"
    request.hostStatus = status
    return request
  }

  func testApprovalForListedHostIsShortAndAllowIsDefault() {
    let presentation = ApprovalPresentation.make(
      for: httpRequest(host: "api.stripe.com", status: .listed), credential: stripeCredential(),
      projectName: "demo-project", risk: nil)
    XCTAssertEqual(presentation.headline, "Claude Code wants to use your Stripe key")
    XCTAssertEqual(presentation.subtitle, "in demo-project")
    XCTAssertEqual(
      presentation.facts,
      [.init("For", "Check the balance"), .init("Sends to", "✓ api.stripe.com")])
    XCTAssertNil(presentation.warning)
    XCTAssertFalse(presentation.denyIsDefault)
    XCTAssertFalse(presentation.detailsExpanded)
  }

  func testApprovalForUnlistedHostWarnsAndDefaultsToDeny() {
    let presentation = ApprovalPresentation.make(
      for: httpRequest(host: "hooks.example.dev", status: .unlisted(allowed: ["api.stripe.com"])),
      credential: stripeCredential(), projectName: "demo-project", risk: nil)
    XCTAssertEqual(
      presentation.headline, "Claude Code wants to send your Stripe key somewhere new")
    XCTAssertEqual(presentation.warning?.title, "hooks.example.dev isn't one of this key's usual websites")
    XCTAssertTrue(presentation.warning?.message.contains("api.stripe.com") ?? false)
    XCTAssertTrue(presentation.denyIsDefault)
    XCTAssertTrue(presentation.detailsExpanded)
    XCTAssertEqual(presentation.rememberableHost, "hooks.example.dev")
  }

  func testApprovalForRiskyCommandLeadsWithWarning() {
    let request = AgentRequest(
      agentID: "claude-code", agentDisplayName: "Claude Code", projectPath: "/tmp/demo",
      credentialIdentifier: UUID().uuidString, executablePath: "/usr/bin/curl",
      arguments: ["https://example.com"])
    let risk = CommandRiskAnalyzer.assess(
      executablePath: "/usr/bin/curl", arguments: request.arguments)
    let presentation = ApprovalPresentation.make(
      for: request, credential: stripeCredential(), projectName: nil, risk: risk)
    XCTAssertEqual(presentation.headline, "Claude Code wants to run a command with your Stripe key")
    XCTAssertEqual(presentation.warning?.title, "Review this command")
    XCTAssertTrue(presentation.denyIsDefault)
    XCTAssertTrue(presentation.detailsExpanded)
  }

  func testApprovalForAkbRunNamesCommandAndKeys() {
    var request = AgentRequest(
      agentID: "terminal", agentDisplayName: "Terminal", projectPath: "/tmp/demo",
      credentialIdentifier: "", executablePath: "/opt/homebrew/bin/npm", arguments: ["run", "dev"])
    request.kind = .environment
    request.environmentVariables = ["OPENAI_API_KEY", "STRIPE_SECRET_KEY"]
    let presentation = ApprovalPresentation.make(
      for: request, credential: nil, projectName: "demo-project",
      risk: CommandRiskAnalyzer.assess(executablePath: "/opt/homebrew/bin/npm", arguments: ["run", "dev"]))
    XCTAssertEqual(presentation.headline, "Terminal wants to start npm run dev with 2 keys")
    XCTAssertEqual(presentation.facts.last, .init("Keys", "OPENAI_API_KEY, STRIPE_SECRET_KEY"))
    XCTAssertFalse(presentation.denyIsDefault, "npm is elevated, not high risk")
  }

  // MARK: - Project folder setup

  private func makeProjectFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "akb-scan-\(UUID().uuidString.prefix(8))/my-app")
    let fm = FileManager.default
    func write(_ path: String, _ text: String) throws {
      let url = root.appendingPathComponent(path)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try write(".gitignore", "node_modules/\n.env\n")
    try write(".env", "OPENAI_API_KEY=sk-shared\nPORT=3000\nSTRIPE_SECRET_KEY=sk_test_1\n")
    try write(".env.local", "OPENAI_API_KEY=sk-local-override\n")
    try write(".env.example", "OPENAI_API_KEY=replace-me\n")
    try write("node_modules/pkg/.env", "LEAKED_DEPENDENCY_KEY=nope\n")
    try write("keys/AuthKey_ABC123DEF4.p8", "-----BEGIN PRIVATE KEY-----\nMIGT\n-----END PRIVATE KEY-----\n")
    try write("certs/server.pem", "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n")
    try write(
      "firebase-admin.json",
      #"{"type":"service_account","project_id":"demo-prod","private_key":"-----BEGIN PRIVATE KEY-----"}"#)
    try write("package.json", #"{"name":"my-app"}"#)
    return root
  }

  func testProjectScanFindsSecretsAndKeyFilesButNotTemplatesOrDependencies() throws {
    let root = try makeProjectFixture()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let scan = ProjectScanner.scan(root)

    XCTAssertEqual(scan.projectName, "my-app")
    XCTAssertEqual(scan.secrets.map(\.key), ["OPENAI_API_KEY", "PORT", "STRIPE_SECRET_KEY"])
    let openAI = try XCTUnwrap(scan.secrets.first { $0.key == "OPENAI_API_KEY" })
    XCTAssertEqual(openAI.value, "sk-local-override", ".env.local overrides .env")
    XCTAssertEqual(openAI.sourceFile, ".env.local")
    XCTAssertEqual(scan.secrets.first { $0.key == "PORT" }?.looksSecret, false)

    XCTAssertEqual(scan.keyFiles.map(\.relativePath), ["firebase-admin.json", "keys/AuthKey_ABC123DEF4.p8"])
    let ascKey = try XCTUnwrap(scan.keyFiles.first { $0.kind == .p8 })
    XCTAssertEqual(ascKey.keyID, "ABC123DEF4")
    XCTAssertEqual(ascKey.service, "Apple App Store Connect")
    XCTAssertEqual(scan.keyFiles.first { $0.kind == .json }?.label, "demo-prod service account")
  }

  func testProjectScanReportsEnvFilesMissingFromGitignoreAndCanFixThem() throws {
    let root = try makeProjectFixture()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    XCTAssertEqual(ProjectScanner.scan(root).envFilesNotIgnored, [".env.local"])
    try GitIgnore.addEntries([".env.local"], to: root)
    XCTAssertEqual(ProjectScanner.scan(root).envFilesNotIgnored, [])
    let gitignore = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
    XCTAssertTrue(gitignore.hasPrefix("node_modules/\n.env\n"), "existing rules are kept")
  }

  func testGitIgnoreMatchingRules() {
    XCTAssertTrue(GitIgnore.matches(".env*", path: ".env.local"))
    XCTAssertTrue(GitIgnore.matches(".env", path: "apps/web/.env"))
    XCTAssertFalse(GitIgnore.matches("/.env", path: "apps/web/.env"))
    XCTAssertTrue(GitIgnore.matches("**/.env.local", path: "apps/web/.env.local"))
    XCTAssertFalse(GitIgnore.matches("node_modules/", path: "node_modules"))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "akb-gi-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try? ".env*\n!.env.production\n".write(
      to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    XCTAssertEqual(
      GitIgnore.unignored([".env", ".env.production"], in: root), [".env.production"],
      "negation re-includes a file")
  }

  func testProjectOutsideGitNeedsNoGitignore() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "akb-nogit-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "A_TOKEN=x\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    XCTAssertEqual(ProjectScanner.scan(root).envFilesNotIgnored, [])
  }

  func testAppStoreConnectKeyIDParsing() {
    XCTAssertEqual(ProjectScanner.appStoreConnectKeyID(fromFileName: "AuthKey_X7KD91.p8"), "X7KD91")
    XCTAssertNil(ProjectScanner.appStoreConnectKeyID(fromFileName: "AuthKey_.p8"))
    XCTAssertNil(ProjectScanner.appStoreConnectKeyID(fromFileName: "key.p8"))
    XCTAssertTrue(ProjectScanner.isEnvFile(".env.development.local"))
    XCTAssertFalse(ProjectScanner.isEnvFile(".env.example"))
    XCTAssertFalse(ProjectScanner.isEnvFile(".envrc"))
  }

  // MARK: - Access log and key cards

  func testAccessLogPersistsNewestFirstAndCapsLength() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "akb-log-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = AccessLogStore(fileURL: url, limit: 3)
    let key = UUID()
    for i in 0..<5 {
      try store.append(
        AccessEvent(
          requestID: UUID(), agentDisplayName: "Agent \(i)", credentialLabel: "STRIPE",
          projectPath: "/tmp", decision: i == 4 ? .deny : .allowOnce,
          timestamp: Date(timeIntervalSince1970: TimeInterval(i * 60)), credentialIDs: [key]))
    }
    let reloaded = AccessLogStore(fileURL: url, limit: 3).load()
    XCTAssertEqual(reloaded.map(\.agentDisplayName), ["Agent 4", "Agent 3", "Agent 2"])
    XCTAssertEqual(reloaded.lastUse(of: key)?.agentDisplayName, "Agent 3", "denials are not uses")
    XCTAssertNil(reloaded.lastUse(of: UUID()))
    let perms = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
      as? NSNumber)?.intValue
    XCTAssertEqual(perms, 0o600)
  }

  func testAccessEventsWithoutCredentialIDsStillDecode() throws {
    let old = #"[{"id":"3BB35765-FD77-484F-99B2-E2181D934056","requestID":"3BB35765-FD77-484F-99B2-E2181D934057","agentDisplayName":"Claude Code","credentialLabel":"X","projectPath":"/tmp","decision":"allowOnce","timestamp":"2026-10-05T00:00:00Z"}]"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let events = try decoder.decode([AccessEvent].self, from: Data(old.utf8))
    XCTAssertNil(events.first?.credentialIDs)
  }

  func testCardUsageAndAttentionText() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func used(_ ago: TimeInterval) -> AccessEvent {
      AccessEvent(
        requestID: UUID(), agentDisplayName: "Claude Code", credentialLabel: "X",
        projectPath: "/tmp", decision: .allowOnce, timestamp: now.addingTimeInterval(-ago))
    }
    XCTAssertEqual(CredentialCardText.usage(nil, now: now), "Not used yet")
    XCTAssertEqual(CredentialCardText.usage(used(20), now: now), "Used by Claude Code · just now")
    XCTAssertEqual(CredentialCardText.usage(used(125), now: now), "Used by Claude Code · 2 min ago")
    XCTAssertEqual(CredentialCardText.usage(used(7200), now: now), "Used by Claude Code · 2 hr ago")
    XCTAssertEqual(CredentialCardText.usage(used(100_000), now: now), "Used by Claude Code · yesterday")

    XCTAssertEqual(
      CredentialCardText.attention(for: CredentialMetadata(label: "DEMO", service: "Demo")),
      "Can be sent to any website")
    XCTAssertNil(
      CredentialCardText.attention(
        for: CredentialMetadata(label: "S", service: "Stripe", allowedHosts: ["api.stripe.com"])))
    XCTAssertNil(
      CredentialCardText.attention(
        for: CredentialMetadata(label: "AuthKey.p8", service: "Apple", kind: .p8)),
      "file keys are never sent by http_request")
  }

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
    /// The listener binds asynchronously; slower CI machines need more than a fixed delay.
    private func waitForSocket(_ socket: URL, timeout: TimeInterval = 5) async throws {
      let deadline = Date().addingTimeInterval(timeout)
      while !FileManager.default.fileExists(atPath: socket.path) {
        guard Date() < deadline else {
          XCTFail("Broker socket was not created within \(timeout)s")
          return
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      // The socket file appears at bind time; give the listener a moment to start accepting.
      try await Task.sleep(for: .milliseconds(100))
    }

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
      try await waitForSocket(fixture.socket)

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
      try await waitForSocket(fixture.socket)

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
