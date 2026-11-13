import Foundation
import XCTest

@testable import AgentKeyBoxCore

#if os(macOS) && DEBUG
  import Darwin

  final class HelperUpdateProcessTests: XCTestCase {
    private let rejection = "Requests must come from the AgentKeyBox helper or akb."

    private actor Reply {
      let executable: URL
      let replacement: URL?
      let message: String
      private var calls = 0

      init(executable: URL, replacement: URL?, message: String) {
        self.executable = executable
        self.replacement = replacement
        self.message = message
      }

      func respond() -> BrokerResponse {
        // The first request proves main() has run. Replace only the disposable executable,
        // before replying, without changing the broker's real peer-signature policy.
        if calls == 0, let replacement {
          XCTAssertEqual(rename(replacement.path, executable.path), 0)
        }
        calls += 1
        return BrokerResponse(ok: false, error: message)
      }

      var count: Int { calls }
    }

    private func runClient(
      _ name: String, arguments: [String] = [], input: Data = Data(),
      replace: Bool, message: String, expectedCalls: Int
    ) async throws -> (output: Data, error: String, status: Int32) {
      let source = try TestProducts.executable(
        name, bundleURL: Bundle(for: Self.self).bundleURL)
      let profile = DevelopmentProfile(id: UUID())
      let root = profile.directory
      defer { try? FileManager.default.removeItem(at: root) }
      let token = try BrokerTokenStore(fileURL: profile.file("broker-token")).loadOrCreate()
      let executable = profile.file(name)
      try FileManager.default.copyItem(at: source, to: executable)
      let replacement = replace ? profile.file(name + ".new") : nil
      if let replacement {
        // Identical contents still represent a different on-disk executable identity.
        try FileManager.default.copyItem(at: executable, to: replacement)
      }
      let reply = Reply(executable: executable, replacement: replacement, message: message)
      let server = LocalBrokerServer(
        socketURL: profile.file("broker.sock"), expectedAuthToken: token, peerPolicy: .unverified
      ) { _ in await reply.respond() }
      try server.start()
      defer { server.stop() }

      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      process.environment = ProcessInfo.processInfo.environment.merging([
        "AGENTKEYBOX_QA_ID": profile.id.uuidString,
        "AGENTKEYBOX_PROJECT_PATH": root.path,
      ]) { _, fixture in fixture }
      process.currentDirectoryURL = root
      let stdin = Pipe()
      let stdout = Pipe()
      let stderr = Pipe()
      process.standardInput = stdin
      process.standardOutput = stdout
      process.standardError = stderr
      try process.run()
      let timeout = DispatchWorkItem {
        if process.isRunning { process.terminate() }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
      defer {
        timeout.cancel()
        if process.isRunning {
          process.terminate()
          process.waitUntilExit()
        }
      }
      try stdin.fileHandleForWriting.write(contentsOf: input)
      try stdin.fileHandleForWriting.close()
      // Drain stdout while it runs so even a failed assertion cannot fill the pipe and hang.
      let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
      process.waitUntilExit()
      let error = String(
        decoding: try stderr.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
      XCTAssertEqual(process.terminationReason, .exit, "Client timed out or crashed")
      let calls = await reply.count
      XCTAssertEqual(calls, expectedCalls)
      return (output, error, process.terminationStatus)
    }

    private func toolCalls(_ calls: [(String, [String: String])]) throws -> Data {
      var input = Data()
      for (index, call) in calls.enumerated() {
        input.append(
          try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": index + 1, "method": "tools/call",
            "params": ["name": call.0, "arguments": call.1],
          ]))
        input.append(0x0A)
      }
      return input
    }

    private func toolMessages(_ output: Data) throws -> [String] {
      try output.split(separator: 0x0A).map { line in
        let response = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        return try XCTUnwrap(content.first?["text"] as? String)
      }
    }

    private func updateMessages(for kind: BrokerClientKind) -> Set<String> {
      defer { Localization.setOverride(nil) }
      return Set(
        [AppLanguage.english, .traditionalChinese].map {
          Localization.setOverride($0)
          return kind.updatedMessage
        })
    }

    func testAllMCPBrokerErrorPathsPreserveUpdateMessage() async throws {
      let id = UUID().uuidString
      let calls: [(String, [String: String])] = [
        ("list_credentials", [:]),
        // This creates a new client AFTER replacement; it must keep the startup snapshot.
        ("request_credential", ["env_var": "TEST_KEY"]),
        (
          "run_with_secret",
          ["credential_id": id, "env_var": "TEST_KEY", "command": "/usr/bin/true"]
        ),
        ("http_request", ["credential_id": id, "url": "https://example.com"]),
        ("browser_login", ["credential_id": id]),
        ("browser_read", ["browser_session_id": id]),
        ("browser_follow", ["browser_session_id": id, "link_id": id]),
        ("browser_recover", ["browser_session_id": id, "credential_id": id]),
        ("browser_close", ["browser_session_id": id]),
      ]
      var input = try toolCalls(calls)
      input.append(
        try JSONSerialization.data(withJSONObject: [
          "jsonrpc": "2.0", "id": 10, "method": "tools/call",
          "params": [
            "name": "submit_sensitive_fields",
            "arguments": ["credential_id": id, "fields": ["code": "{{recovery.code}}"]],
          ],
        ]))
      input.append(0x0A)
      let result = try await runClient(
        "agentkeybox-mcp", input: input, replace: true, message: rejection, expectedCalls: 10)
      XCTAssertEqual(result.status, 0)
      XCTAssertEqual(result.error, "")
      let messages = try toolMessages(result.output)
      XCTAssertEqual(messages.count, 10)
      let expected = updateMessages(for: .mcpHelper)
      for message in messages { XCTAssertTrue(expected.contains(message), message) }
    }

    func testUnchangedHelperKeepsRejectionAndControlledToolsHideRawDiagnostics() async throws {
      for (replace, message) in [(false, rejection), (true, "private-diagnostic")] {
        let input = try toolCalls([
          ("list_credentials", [:]),
          ("browser_read", ["browser_session_id": UUID().uuidString]),
        ])
        let result = try await runClient(
          "agentkeybox-mcp", input: input, replace: replace, message: message, expectedCalls: 2)
        XCTAssertEqual(result.status, 0)
        let messages = try toolMessages(result.output)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first, message)
        XCTAssertEqual(
          messages.last,
          "The browser operation did not return a result. Review browser access in AgentKeyBox before retrying a sign-in."
        )
      }
    }

    func testBrowserCLIPreservesOnlyTypedUpdateGuidance() async throws {
      let result = try await runClient(
        "akb", arguments: ["browser", "list"], replace: true,
        message: rejection, expectedCalls: 1)
      XCTAssertEqual(result.status, 1)
      XCTAssertTrue(result.output.isEmpty)
      XCTAssertTrue(updateMessages(for: .commandLine).map { $0 + "\n" }.contains(result.error))

      let unrelated = try await runClient(
        "akb", arguments: ["browser", "list"], replace: true,
        message: "private-diagnostic", expectedCalls: 1)
      XCTAssertEqual(unrelated.status, 1)
      XCTAssertTrue(unrelated.output.isEmpty)
      XCTAssertEqual(
        unrelated.error, BrowserAgentResult.ResultError.unavailable.localizedDescription + "\n")
    }
  }
#endif
