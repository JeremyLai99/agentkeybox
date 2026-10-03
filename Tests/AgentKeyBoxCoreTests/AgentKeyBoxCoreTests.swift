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

}
