import AgentKeyBoxCore
import Foundation

private struct JSONRPCRequest: Decodable {
  let jsonrpc: String
  let id: JSONValue?
  let method: String
  let params: JSONValue?
}

private indirect enum JSONValue: Codable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }
}

@main
struct AgentKeyBoxMCP {
  static func main() async {
    let server = MCPServer()
    await server.run()
  }
}

private final class MCPServer: @unchecked Sendable {
  private let client = LocalBrokerClient()
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  func run() async {
    while let line = readLine(strippingNewline: true) {
      guard line.utf8.count <= 256 * 1024 else {
        write(errorResponse(id: nil, code: -32600, message: "Request too large"))
        continue
      }
      guard let data = line.data(using: .utf8) else { continue }
      do {
        let request = try decoder.decode(JSONRPCRequest.self, from: data)
        if request.id == nil {
          continue  // notification
        }
        guard request.jsonrpc == "2.0" else {
          write(errorResponse(id: request.id, code: -32600, message: "Invalid Request"))
          continue
        }
        let response = await handle(request)
        write(response)
      } catch {
        write(errorResponse(id: nil, code: -32700, message: "Parse error"))
      }
    }
  }

  private func handle(_ request: JSONRPCRequest) async -> [String: JSONValue] {
    switch request.method {
    case "initialize":
      return success(
        id: request.id,
        result: .object([
          "protocolVersion": .string("2025-06-18"),
          "capabilities": .object(["tools": .object([:])]),
          "serverInfo": .object([
            "name": .string("AgentKeyBox"),
            "version": .string("0.3.0"),
          ]),
          "instructions": .string(
            "Use AgentKeyBox when a task needs a developer credential. Call list_credentials first. To call a provider's HTTPS API, prefer http_request with {{secret}} in a header. To run a local tool that reads the credential from an environment variable, use run_with_secret. If the credential is missing, call request_credential so the user can enter it in AgentKeyBox. Never ask the user to paste raw secrets into chat."
          ),
        ]))

    case "ping":
      return success(id: request.id, result: .object([:]))

    case "tools/list":
      return success(
        id: request.id,
        result: .object([
          "tools": .array([
            listCredentialsTool(), httpRequestTool(), runWithSecretTool(), requestCredentialTool(),
          ])
        ]))

    case "tools/call":
      return await handleToolCall(request)

    default:
      return errorResponse(id: request.id, code: -32601, message: "Method not found")
    }
  }

  private func handleToolCall(_ request: JSONRPCRequest) async -> [String: JSONValue] {
    guard let params = request.params?.objectValue,
      let name = params["name"]?.stringValue
    else {
      return errorResponse(id: request.id, code: -32602, message: "Invalid tool call")
    }
    let args = params["arguments"]?.objectValue ?? [:]

    switch name {
    case "list_credentials":
      let projectPath = trustedProjectPath()
      let agent = agentIdentity()
      do {
        let response = try await client.send(
          BrokerRequest(
            action: .listCredentials,
            agentID: agent.id,
            agentDisplayName: agent.name,
            projectPath: projectPath
          ))
        let items = (response.credentials ?? []).map { item in
          [
            item.id.uuidString,
            item.label,
            item.service,
            "env_var=\(item.environmentVariableName ?? "-")",
            "allowed_hosts=\(item.allowedHosts?.joined(separator: ",") ?? "any")",
            "environment=\(item.environment ?? "unspecified")",
            item.kind.rawValue,
          ].joined(separator: " | ")
        }
        let text =
          items.isEmpty
          ? "No credentials are available to this project in AgentKeyBox. Call request_credential with the environment variable name the project expects, so the user can enter it in AgentKeyBox."
          : "id | label | service | env_var | allowed_hosts | environment | kind\n"
            + items.joined(separator: "\n")
        return toolResult(id: request.id, text: text)
      } catch {
        return toolError(id: request.id, message: error.localizedDescription)
      }

    case "run_with_secret":
      return await runWithSecret(requestID: request.id, args: args)

    case "http_request":
      return await httpRequest(requestID: request.id, args: args)

    case "request_credential":
      return await requestCredential(requestID: request.id, args: args)

    default:
      return toolError(id: request.id, message: "Unknown AgentKeyBox tool: \(name)")
    }
  }

  private func runWithSecret(requestID: JSONValue?, args: [String: JSONValue]) async -> [String:
    JSONValue]
  {
    guard let credentialID = args["credential_id"]?.stringValue,
      let envVar = args["env_var"]?.stringValue,
      let command = args["command"]?.stringValue
    else {
      return toolError(id: requestID, message: "credential_id, env_var, and command are required.")
    }

    guard command.hasPrefix("/") else {
      return toolError(id: requestID, message: "command must be an absolute executable path.")
    }

    let commandArgs = args["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let projectPath = trustedProjectPath()
    let purpose = args["purpose"]?.stringValue
    let deliveryRaw = args["delivery"]?.stringValue ?? SecretDeliveryMode.environment.rawValue
    guard let deliveryMode = SecretDeliveryMode(rawValue: deliveryRaw) else {
      return toolError(id: requestID, message: "delivery must be environment or tempFile.")
    }
    let agent = agentIdentity()

    do {
      let response = try await client.send(
        BrokerRequest(
          action: .executeWithSecret,
          agentID: agent.id,
          agentDisplayName: agent.name,
          projectPath: projectPath,
          credentialIdentifier: credentialID,
          purpose: purpose,
          executablePath: command,
          arguments: commandArgs,
          environmentVariable: envVar,
          deliveryMode: deliveryMode,
          requestedScope: .once,
          sessionID: ProcessInfo.processInfo.environment["AGENTKEYBOX_SESSION_ID"]
        ))

      guard response.decision != .deny else {
        return toolError(id: requestID, message: "Credential access was denied.")
      }
      guard let execution = response.execution else {
        return toolError(
          id: requestID,
          message: "AgentKeyBox approved the request but did not return an execution result.")
      }

      var text = "exit_code=\(execution.exitCode)\n\(execution.output)"
      if execution.outputTruncated {
        text += "\nAgentKeyBox truncated the captured output."
      }
      return toolResult(id: requestID, text: text)
    } catch {
      return toolError(id: requestID, message: error.localizedDescription)
    }
  }

  private func httpRequest(requestID: JSONValue?, args: [String: JSONValue]) async -> [String:
    JSONValue]
  {
    guard let credentialID = args["credential_id"]?.stringValue,
      let url = args["url"]?.stringValue
    else {
      return toolError(id: requestID, message: "credential_id and url are required.")
    }
    var headers: [String: String] = [:]
    for (name, value) in args["headers"]?.objectValue ?? [:] {
      guard let text = value.stringValue else {
        return toolError(id: requestID, message: "Header values must be strings.")
      }
      headers[name] = text
    }
    let agent = agentIdentity()

    do {
      let response = try await client.send(
        BrokerRequest(
          action: .httpRequest,
          agentID: agent.id,
          agentDisplayName: agent.name,
          projectPath: trustedProjectPath(),
          credentialIdentifier: credentialID,
          purpose: args["purpose"]?.stringValue,
          httpMethod: args["method"]?.stringValue ?? "GET",
          url: url,
          headers: headers,
          body: args["body"]?.stringValue
        ))
      guard response.decision != .deny else {
        return toolError(id: requestID, message: "Credential access was denied.")
      }
      guard let http = response.http else {
        return toolError(
          id: requestID, message: "AgentKeyBox approved the request but returned no response.")
      }
      var text = "status=\(http.statusCode)\ncontent_type=\(http.contentType ?? "-")\n\n\(http.body)"
      if http.bodyTruncated {
        text += "\nAgentKeyBox truncated the response body."
      }
      return toolResult(id: requestID, text: text)
    } catch {
      return toolError(id: requestID, message: error.localizedDescription)
    }
  }

  private func requestCredential(requestID: JSONValue?, args: [String: JSONValue]) async -> [String:
    JSONValue]
  {
    guard let envVar = args["env_var"]?.stringValue else {
      return toolError(id: requestID, message: "env_var is required.")
    }
    let agent = agentIdentity()
    // The user may need several minutes to create the key in the provider's dashboard.
    let longClient = LocalBrokerClient(timeoutSeconds: BrokerEndpoint.credentialRequestClientTimeout)

    do {
      let response = try await longClient.send(
        BrokerRequest(
          action: .requestCredential,
          agentID: agent.id,
          agentDisplayName: agent.name,
          projectPath: trustedProjectPath(),
          purpose: args["purpose"]?.stringValue,
          environmentVariable: envVar,
          credentialService: args["service"]?.stringValue
        ))
      guard let credential = response.credentials?.first else {
        return toolError(id: requestID, message: "AgentKeyBox did not return a credential.")
      }
      return toolResult(
        id: requestID,
        text:
          "The credential is stored in AgentKeyBox. Use it with credential_id=\(credential.id.uuidString) (env_var=\(credential.environmentVariableName ?? envVar), allowed_hosts=\(credential.allowedHosts?.joined(separator: ",") ?? "any")). The secret value itself is not available to you."
      )
    } catch {
      return toolError(id: requestID, message: error.localizedDescription)
    }
  }

  private func trustedProjectPath() -> String {
    let env = ProcessInfo.processInfo.environment
    if let claudeProject = env["CLAUDE_PROJECT_DIR"], !claudeProject.isEmpty {
      return normalized(claudeProject)
    }
    if let explicit = env["AGENTKEYBOX_PROJECT_PATH"], !explicit.isEmpty {
      return normalized(explicit)
    }
    return normalized(FileManager.default.currentDirectoryPath)
  }

  private func normalized(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
  }

  private func agentIdentity() -> (id: String, name: String) {
    let env = ProcessInfo.processInfo.environment
    if let id = env["AGENTKEYBOX_AGENT_ID"], let name = env["AGENTKEYBOX_AGENT_NAME"] {
      return (id, name)
    }
    if env["CODEX_HOME"] != nil || env["CODEX_SANDBOX"] != nil {
      return ("codex", "Codex")
    }
    return ("coding-agent", "Coding Agent")
  }

  private func listCredentialsTool() -> JSONValue {
    .object([
      "name": .string("list_credentials"),
      "description": .string(
        "List non-secret AgentKeyBox credential metadata available to the current local project. Secret values are never returned."
      ),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
      ]),
    ])
  }

  private func httpRequestTool() -> JSONValue {
    .object([
      "name": .string("http_request"),
      "description": .string(
        "Ask the user to approve one HTTPS request that needs a stored credential. AgentKeyBox sends the request itself and returns the status and redacted response body; you never receive the secret. Put {{secret}} in a header value where the credential belongs, e.g. {\"Authorization\": \"Bearer {{secret}}\"}. Requests are only sent to the credential's allowed hosts, and redirects are not followed."
      ),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "credential_id": .object([
            "type": .string("string"),
            "description": .string("Credential UUID returned by list_credentials."),
          ]),
          "method": .object([
            "type": .string("string"),
            "enum": .array(
              ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].map { JSONValue.string($0) }),
          ]),
          "url": .object([
            "type": .string("string"),
            "description": .string("Full https URL. Must not contain {{secret}}."),
          ]),
          "headers": .object([
            "type": .string("object"),
            "additionalProperties": .object(["type": .string("string")]),
            "description": .string(
              "Request headers. At least one value must contain {{secret}}."),
          ]),
          "body": .object([
            "type": .string("string"),
            "description": .string("Optional request body. Must not contain {{secret}}."),
          ]),
          "purpose": .object([
            "type": .string("string"),
            "description": .string("Short user-readable reason for this request."),
          ]),
        ]),
        "required": .array([.string("credential_id"), .string("url"), .string("headers")]),
        "additionalProperties": .bool(false),
      ]),
    ])
  }

  private func requestCredentialTool() -> JSONValue {
    .object([
      "name": .string("request_credential"),
      "description": .string(
        "Ask the user to add a credential that list_credentials does not show. AgentKeyBox opens a prompt where the user pastes the key (with a link to the provider's dashboard); it is saved for the current project and you receive only its credential_id. Use this instead of asking the user to paste a key into chat."
      ),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "env_var": .object([
            "type": .string("string"),
            "description": .string(
              "Environment variable name the project expects, e.g. STRIPE_SECRET_KEY."),
          ]),
          "service": .object([
            "type": .string("string"),
            "description": .string("Provider name, e.g. Stripe, OpenAI, Supabase."),
          ]),
          "purpose": .object([
            "type": .string("string"),
            "description": .string("Short user-readable reason why the project needs it."),
          ]),
        ]),
        "required": .array([.string("env_var")]),
        "additionalProperties": .bool(false),
      ]),
    ])
  }

  private func runWithSecretTool() -> JSONValue {
    .object([
      "name": .string("run_with_secret"),
      "description": .string(
        "Ask the user to approve one local command that needs a stored credential. AgentKeyBox runs the approved command itself with the credential injected as an environment variable; the MCP process never receives the raw secret. Use an absolute executable path."
      ),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "credential_id": .object([
            "type": .string("string"),
            "description": .string("Credential UUID returned by list_credentials."),
          ]),
          "env_var": .object([
            "type": .string("string"),
            "description": .string(
              "Environment variable name expected by the approved process, e.g. OPENAI_API_KEY."),
          ]),
          "command": .object([
            "type": .string("string"),
            "description": .string(
              "Absolute executable path, e.g. /usr/bin/curl. Shell snippets are not accepted here."),
          ]),
          "args": .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
          ]),
          "purpose": .object([
            "type": .string("string"),
            "description": .string("Short user-readable reason why this credential is needed."),
          ]),
          "delivery": .object([
            "type": .string("string"),
            "enum": .array([.string("environment"), .string("tempFile")]),
            "description": .string(
              "environment injects UTF-8 secret text directly. tempFile writes a protected temporary file and injects its path; use tempFile for .p8, .pem, or JSON files when the target tool expects a path."
            ),
          ]),
        ]),
        "required": .array([.string("credential_id"), .string("env_var"), .string("command")]),
        "additionalProperties": .bool(false),
      ]),
    ])
  }

  private func success(id: JSONValue?, result: JSONValue) -> [String: JSONValue] {
    ["jsonrpc": .string("2.0"), "id": id ?? .null, "result": result]
  }

  private func errorResponse(id: JSONValue?, code: Double, message: String) -> [String: JSONValue] {
    [
      "jsonrpc": .string("2.0"),
      "id": id ?? .null,
      "error": .object(["code": .number(code), "message": .string(message)]),
    ]
  }

  private func toolResult(id: JSONValue?, text: String) -> [String: JSONValue] {
    success(
      id: id,
      result: .object([
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        "isError": .bool(false),
      ]))
  }

  private func toolError(id: JSONValue?, message: String) -> [String: JSONValue] {
    success(
      id: id,
      result: .object([
        "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
        "isError": .bool(true),
      ]))
  }

  private func write(_ object: [String: JSONValue]) {
    guard let data = try? encoder.encode(object),
      let string = String(data: data, encoding: .utf8)
    else { return }
    FileHandle.standardOutput.write(Data((string + "\n").utf8))
  }
}
