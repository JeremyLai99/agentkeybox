import Foundation
import XCTest

@testable import AgentKeyBoxCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class SensitiveItemTests: XCTestCase, @unchecked Sendable {
  private func card() throws -> SensitivePayload {
    SensitivePayload(
      card: try StoredCard(
        number: "4242 4242 4242 4242", cardholder: "Test User",
        expirationMonth: 12, expirationYear: 2030))
  }

  private func codes() throws -> SensitivePayload {
    SensitivePayload(recoveryCodes: try RecoveryCodeSet(text: "abc12-def34\n56789-ab012"))
  }

  private func metadata(_ kind: CredentialKind) -> CredentialMetadata {
    CredentialMetadata(
      label: "Test item", service: "Test", kind: kind,
      environmentVariableName: "TEST_SECRET", allowedHosts: ["elsewhere.example"],
      settings: ["SHOULD_NOT_APPEAR": "private setting"],
      submissionURL: "https://example.com/submit")
  }

  func testTypedPayloadRoundTripAndValidation() throws {
    for payload in [try card(), try codes()] {
      XCTAssertEqual(try SensitivePayload.decode(payload.encoded(), kind: payload.kind), payload)
      XCTAssertThrowsError(try SensitivePayload.decode(payload.encoded(), kind: .apiKey))
      var json = try XCTUnwrap(
        JSONSerialization.jsonObject(with: payload.encoded()) as? [String: Any])
      json["version"] = 99
      XCTAssertThrowsError(
        try SensitivePayload.decode(
          JSONSerialization.data(withJSONObject: json), kind: payload.kind)
      ) {
        XCTAssertEqual($0 as? SensitiveDataError, .unsupportedVersion)
      }
    }
    XCTAssertEqual(try card().card?.number, "4242424242424242")
    for number in ["4242424242424241", "0000000000000000", "４２４２４２４２４２４２４２４２"] {
      XCTAssertThrowsError(
        try StoredCard(number: number, cardholder: "Test", expirationMonth: 1, expirationYear: 2030)
      )
    }
    for text in [
      "", "same-code\nsame-code", "# Recovery Codes\nabc12-def34", "abc12 def34",
      String(repeating: "a", count: 129),
    ] {
      XCTAssertThrowsError(try RecoveryCodeSet(text: text))
    }
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: codes().encoded()) as? [String: Any])
    var set = try XCTUnwrap(json["recoveryCodes"] as? [String: Any])
    var entries = try XCTUnwrap(set["entries"] as? [[String: Any]])
    entries[0]["value"] = "abc12-def34\nextra-code"
    set["entries"] = entries
    json["recoveryCodes"] = set
    XCTAssertThrowsError(
      try SensitivePayload.decode(
        JSONSerialization.data(withJSONObject: json), kind: .recoveryCodes))
  }

  func testAgentMetadataCannotOfferGenericInjectionOrPayload() throws {
    for kind in [CredentialKind.creditCard, .recoveryCodes] {
      let item = metadata(kind)
      XCTAssertNil(item.injectionVariableName)
      let summary = CredentialSummary(metadata: item)
      XCTAssertNil(summary.environmentVariableName)
      XCTAssertNil(summary.settings)
      XCTAssertNil(summary.allowedHosts)
      XCTAssertEqual(summary.submissionURL, "https://example.com/submit")
      let text = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
      XCTAssertFalse(text.contains("private setting"))
      XCTAssertFalse(text.contains("4242424242424242"))
    }
    let old = CredentialMetadata(label: "OLD", service: "Test")
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    json.removeValue(forKey: "submissionURL")
    XCTAssertEqual(
      try JSONDecoder().decode(
        CredentialMetadata.self, from: JSONSerialization.data(withJSONObject: json)), old)
  }

  func testReservationSurvivesRestartAndReplacement() throws {
    var payload = try codes()
    let first = try payload.recoveryCodes?.reserveNext()
    payload = try SensitivePayload.decode(payload.encoded(), kind: .recoveryCodes)
    let second = try payload.recoveryCodes?.reserveNext()
    XCTAssertNotEqual(first, second)
    XCTAssertThrowsError(try payload.recoveryCodes?.reserveNext())
    var replacement = try RecoveryCodeSet(text: "abc12-def34\nnew12-code3")
    replacement.preserveHistory(from: try XCTUnwrap(payload.recoveryCodes))
    XCTAssertEqual(replacement.entries.map(\.status), [.issued, .available])
    XCTAssertEqual(try replacement.reserveNext(), "new12-code3")
  }

  func testRestoreDoesNotReactivateOldCodes() throws {
    var payload = try codes()
    _ = try payload.recoveryCodes?.reserveNext()
    let id = try XCTUnwrap(payload.recoveryCodes?.entries.last?.id)
    payload.recoveryCodes?.setStatus(.used, for: id)
    let restored = try SensitivePayload.decode(
      SensitivePayload.restored(payload.encoded(), kind: .recoveryCodes), kind: .recoveryCodes)
    XCTAssertEqual(restored.recoveryCodes?.entries.map(\.status), [.needsReview, .used])
    var set = try XCTUnwrap(restored.recoveryCodes)
    XCTAssertThrowsError(try set.reserveNext())
    set.setStatus(.available, for: set.entries[0].id)
    XCTAssertEqual(try set.reserveNext(), "abc12-def34")
  }

  func testSubmissionRejectsInvalidDestinationsAndFieldsBeforeReserving() throws {
    for destination in [
      "http://example.com/submit", "https://u:p@example.com/submit",
      "https://example.com/submit?next=evil", "https://example.com/#fragment",
      "https://{{card.number}}/", "",
    ] {
      XCTAssertThrowsError(try SensitiveSubmissionPolicy.destination(destination))
    }
    var payload = try codes()
    let item = metadata(.recoveryCodes)
    for fields in [
      [String: String](), ["code": "{{card.number}}"], ["code": "prefix{{recovery.code}}"],
      ["a": "{{recovery.code}}", "b": "{{recovery.code}}"], ["a\nInjected": "{{recovery.code}}"],
      ["code": "{{recovery.code}}", "data": String(repeating: "a", count: 4097)],
    ] {
      XCTAssertThrowsError(
        try SensitiveSubmissionPolicy.prepare(
          .init(fields: fields), credential: item, payload: &payload))
    }
    XCTAssertEqual(payload.recoveryCodes?.entries.map(\.status), [.available, .available])
    XCTAssertThrowsError(
      try SensitiveSubmissionPolicy.validate(
        .init(fields: ["code": "{{recovery.code}}"]), credential: metadata(.apiKey)))
  }

  func testPreparationOnlyReplacesSelectedWholeFieldsAndEncodesLiterals() throws {
    var payload = try card()
    let item = metadata(.creditCard)
    let submission = SensitiveSubmissionRequest(fields: [
      "pan": "{{card.number}}", "month": "{{card.expiration_month}}", "note": "x&role=admin +中文",
    ])
    let request = try SensitiveSubmissionPolicy.prepare(
      submission, credential: item, payload: &payload)
    XCTAssertEqual(request.url?.absoluteString, item.submissionURL)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.allHTTPHeaderFields?.count, 1)
    let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
    XCTAssertTrue(body.contains("month=12"))
    XCTAssertTrue(body.contains("pan=4242424242424242"))
    XCTAssertTrue(body.contains("x%26role%3Dadmin%20%2B"))
    XCTAssertFalse(body.contains("Test User"))
    XCTAssertFalse(body.contains("2030"))
    let json = try SensitiveSubmissionPolicy.prepare(
      .init(fields: submission.fields, encoding: .json), credential: item, payload: &payload)
    let fields = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(json.httpBody)) as? [String: String])
    XCTAssertEqual(fields["note"], submission.fields["note"])
    XCTAssertEqual(fields["pan"], "4242424242424242")
  }

  @MainActor
  func testPersistenceFailureSendsNothingAndUnknownOutcomeKeepsReservation() async throws {
    enum SaveError: Error { case failed }
    var sent = 0
    let payload = try codes()
    var item = metadata(.recoveryCodes)
    item.payloadRevision = payload.revision
    var saved = try payload.encoded()
    let submission = SensitiveSubmissionRequest(fields: ["code": "{{recovery.code}}"])
    do {
      _ = try await SensitiveSubmissionExecutor.execute(
        submission, credential: item, payload: payload,
        persistReservation: { _ in throw SaveError.failed },
        send: { _ in
          sent += 1
          return .received
        })
      XCTFail("A failed save must stop submission")
    } catch SaveError.failed {}
    XCTAssertEqual(sent, 0)
    let outcome = try await SensitiveSubmissionExecutor.execute(
      submission, credential: item, payload: payload,
      persistReservation: { saved = $0 },
      send: { _ in
        let stored = try? SensitivePayload.decode(saved, kind: .recoveryCodes)
        XCTAssertEqual(stored?.recoveryCodes?.entries.first?.status, .issued)
        sent += 1
        return .unknown
      })
    XCTAssertEqual(outcome, .unknown)
    XCTAssertEqual(sent, 1)
    var reloaded = try SensitivePayload.decode(saved, kind: .recoveryCodes)
    XCTAssertNotEqual(reloaded.revision, payload.revision)
    XCTAssertEqual(try reloaded.recoveryCodes?.reserveNext(), "56789-ab012")
  }

  func testProtectedApprovalNeverGrantsSession() async {
    let engine = ApprovalEngine()
    let item = metadata(.creditCard)
    var request = AgentRequest(
      agentID: "test", agentDisplayName: "Test", projectPath: "/project",
      credentialIdentifier: item.id.uuidString, sessionID: "session")
    request.kind = .sensitiveSubmission
    request.url = item.submissionURL
    XCTAssertFalse(ApprovalEngine.canGrantSession(for: request))
    await engine.grantSession(for: request, authentication: nil)
    let grant = await engine.sessionApproval(for: request)
    XCTAssertNil(grant)
    let presentation = ApprovalPresentation.make(
      for: request, credential: item, projectName: "Project", risk: nil)
    XCTAssertTrue(presentation.denyIsDefault)
    XCTAssertTrue(presentation.detailsExpanded)
    XCTAssertNil(presentation.sessionApprovalLabel)
    XCTAssertNil(presentation.rememberableHost)
    XCTAssertTrue(presentation.facts.contains { $0.value == item.submissionURL })
  }

  func testVersionedBackupKeepsProtectedItemsOutOfEnv() throws {
    let cardPayload = try card()
    let codePayload = try codes()
    var cardItem = metadata(.creditCard)
    var codeItem = metadata(.recoveryCodes)
    cardItem.payloadRevision = cardPayload.revision
    codeItem.payloadRevision = codePayload.revision
    let contents = BackupContents(
      projects: [], credentials: [cardItem, codeItem],
      secrets: [
        cardItem.id.uuidString: try cardPayload.encoded(),
        codeItem.id.uuidString: try codePayload.encoded(),
      ])
    let layout = try BackupArchive.layout(contents)
    XCTAssertFalse(layout.contains { $0.path.hasSuffix("/.env") || $0.path.hasSuffix("/env.txt") })
    XCTAssertTrue(layout.contains { $0.path.hasSuffix(".card.json") })
    XCTAssertTrue(layout.contains { $0.path.hasSuffix(".recovery-codes.json") })
    let data = try XCTUnwrap(layout.first { $0.path == BackupArchive.dataFileName }?.data)
    XCTAssertEqual(try BackupArchive.contents(fromDataFile: data), contents)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["version"] as? Int, 2)
    json["version"] = 1
    XCTAssertThrowsError(
      try BackupArchive.contents(fromDataFile: JSONSerialization.data(withJSONObject: json)))
    let legacy = BackupContents(projects: [], credentials: [], secrets: [:])
    let oldData = try XCTUnwrap(
      BackupArchive.layout(legacy).first { $0.path == BackupArchive.dataFileName }?.data)
    XCTAssertEqual(try JSONDecoder().decode(BackupArchive.DataFile.self, from: oldData).version, 1)
    XCTAssertEqual(try BackupArchive.contents(fromDataFile: oldData), legacy)
  }

  func testExportedProtectedFilesCannotBeMistakenForGenericJSON() throws {
    XCTAssertEqual(SensitivePayload.importedKind(try card().encoded()), .creditCard)
    XCTAssertEqual(SensitivePayload.importedKind(try codes().encoded()), .recoveryCodes)
    XCTAssertEqual(SensitivePayload.importedKind(Data(), filename: "Saved.card.json"), .creditCard)
    XCTAssertEqual(
      SensitivePayload.importedKind(Data(), filename: "Saved.recovery-codes.json"), .recoveryCodes)
    XCTAssertEqual(
      SensitivePayload.importedKind(Data(#"{"version":99,"recoveryCodes":{}}"#.utf8)),
      .recoveryCodes)
    XCTAssertNil(
      SensitivePayload.importedKind(Data(#"{"type":"service_account","project_id":"test"}"#.utf8)))
  }

  @MainActor
  func testPartialEditCannotSubmitMismatchedPayloadOrEnterBackup() async throws {
    let payload = try card()
    var item = metadata(.creditCard)
    item.payloadRevision = UUID()
    do {
      _ = try await SensitiveSubmissionExecutor.execute(
        .init(fields: ["pan": "{{card.number}}"]), credential: item, payload: payload,
        persistReservation: { _ in XCTFail("Must not persist mismatched data") },
        send: { _ in
          XCTFail("Must not send mismatched data")
          return .received
        })
      XCTFail("Must reject a partial edit")
    } catch {
      XCTAssertEqual(error as? SensitiveDataError, .invalidPayload)
    }
    let contents = BackupContents(
      projects: [], credentials: [item], secrets: [item.id.uuidString: try payload.encoded()])
    XCTAssertThrowsError(try BackupArchive.layout(contents))
  }

  func testTransportReturnsFixedResultsWithoutReflectedContentOrDiagnostics() async throws {
    for (path, expected) in [
      ("ok", SensitiveSubmissionOutcome.received), ("reject", .rejected),
      ("redirect", .redirectBlocked), ("error", .unknown),
    ] {
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [ProtectedResponseFixture.self]
      let outcome = await SensitiveSubmissionTransport.send(
        URLRequest(url: URL(string: "https://example.com/\(path)")!), configuration: config)
      XCTAssertEqual(outcome, expected)
      let response = BrokerResponse(ok: true, decision: .allowOnce, submissionOutcome: outcome)
      let json = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
      XCTAssertEqual(Set(json.keys), ["ok", "decision", "submissionOutcome"])
      XCTAssertEqual(json["submissionOutcome"] as? String, expected.rawValue)
    }
  }

  #if os(macOS)
    func testTransportDoesNotFollowRealNetworkRedirect() async throws {
      let server = try TinyHTTPServer()
      defer { server.stop() }
      // Only the internal transport uses HTTP for this loopback fixture. Public policy requires HTTPS.
      let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/redirect")!)
      let result = await SensitiveSubmissionTransport.send(request)
      XCTAssertEqual(result, .redirectBlocked)
      XCTAssertEqual(server.requestedPaths, ["/redirect"])
    }
  #endif
}

/// Synthetic data only. All upstream-controlled strings must be absent from broker results.
private final class ProtectedResponseFixture: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let path = request.url!.lastPathComponent
    if path == "error" {
      client?.urlProtocol(
        self,
        didFailWithError: NSError(
          domain: "secret-abc12-def34", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "reflected=4242424242424242"]))
      return
    }
    let code = path == "redirect" ? 302 : path == "reject" ? 422 : 200
    let response = HTTPURLResponse(
      url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
      headerFields: [
        "Location": "https://elsewhere.example/4242424242424242", "X-Secret": "abc12-def34",
      ])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(
      self, didLoad: Data("raw=4242424242424242 encoded=NDI0MjQyNDI0MjQyNDI0Mg==".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
