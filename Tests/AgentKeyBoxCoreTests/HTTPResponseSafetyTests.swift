import Foundation
import XCTest

@testable import AgentKeyBoxCore

final class HTTPResponseSafetyTests: XCTestCase {
  func testMIMEParserBoundsTokensDropsParametersAndRejectsSecrets() {
    let secret = Data("SyntheticSecret".utf8)
    XCTAssertEqual(
      HTTPRequestExecutor.safeContentType(
        " Text/Plain ; reflected=SyntheticSecret", secretData: secret),
      "text/plain")
    for raw in [
      nil, "", "/plain", "text/", "text/plain/extra", "text/pl ain", "text/中文",
      "text/plain\r\nInjected: x", "text/plain,other/type",
      "text/" + String(repeating: "a", count: 128),
      "text/SyntheticSecret", "text/syntheticsecret",
    ] {
      XCTAssertNil(HTTPRequestExecutor.safeContentType(raw, secretData: secret))
    }
    XCTAssertEqual(
      HTTPRequestExecutor.safeContentType("application/vnd.example+json", secretData: secret),
      "application/vnd.example+json")
  }

  #if os(macOS)
    func testLoopbackReflectedMIMEIsAbsentFromBrokerAndMCPOutput() async throws {
      let server = try TinyHTTPServer()
      defer { server.stop() }
      let secret = Data("Synthetic-Key-42!".utf8)
      let variants = SecretRedactor.candidates(for: secret)
      for variant in variants {
        for path in ["/mime-parameter", "/mime-subtype"] {
          let request = ValidatedHTTPRequest(
            method: "GET", url: URL(string: "http://127.0.0.1:\(server.port)\(path)")!,
            host: "127.0.0.1", headers: ["Authorization": variant], body: nil, hostStatus: .listed)
          let result = try await HTTPRequestExecutor.execute(request, secretData: secret)
          XCTAssertEqual(result.contentType, path == "/mime-parameter" ? "text/plain" : nil)
          let response = BrokerResponse(ok: true, http: result)
          let encoded = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
          for candidate in variants {
            XCTAssertFalse(encoded.lowercased().contains(candidate.lowercased()))
            XCTAssertFalse(result.agentText.lowercased().contains(candidate.lowercased()))
          }
        }
      }
    }

    func testTransportFailureReturnsFixedDiagnosticWithoutUpstreamURL() async throws {
      let server = try TinyHTTPServer()
      defer { server.stop() }
      let secret = "synthetic-upstream-secret"
      let request = ValidatedHTTPRequest(
        method: "GET", url: URL(string: "http://127.0.0.1:\(server.port)/disconnect?\(secret)")!,
        host: "127.0.0.1", headers: [:], body: nil, hostStatus: .listed)
      do {
        _ = try await HTTPRequestExecutor.execute(request, secretData: Data(secret.utf8))
        XCTFail("Disconnected server must fail")
      } catch {
        XCTAssertEqual(error as? HTTPRequestExecutorError, .transport)
        XCTAssertEqual(
          error.localizedDescription, HTTPRequestExecutorError.transport.localizedDescription)
        for variant in SecretRedactor.candidates(for: Data(secret.utf8)) {
          XCTAssertFalse(error.localizedDescription.contains(variant))
        }
      }
    }
  #endif
}
