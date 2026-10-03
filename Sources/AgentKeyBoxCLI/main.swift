import AgentKeyBoxCore
import Foundation

struct DoctorCheck: Codable {
  var name: String
  var status: String
  var detail: String
}

@main
struct AgentKeyBoxCLI {
  static func main() async {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
      printHelp()
      return
    }

    switch command {
    case "doctor", "status":
      let json = args.contains("--json")
      await doctor(json: json)
    case "connect":
      guard args.count >= 2 else {
        writeError("Usage: akb connect <claude|codex|all> [--helper /path/to/agentkeybox-mcp]\n")
        exit(2)
      }
      let target = args[1]
      let helper = argumentValue("--helper", in: args) ?? MCPExecutableLocator.locate()
      guard let helper else {
        writeError(
          "agentkeybox-mcp was not found. Build/install AgentKeyBox first or pass --helper.\n")
        exit(1)
      }
      await connect(target: target, helper: helper)
    case "helper-path":
      if let helper = MCPExecutableLocator.locate() {
        print(helper)
      } else {
        exit(1)
      }
    case "help", "--help", "-h":
      printHelp()
    default:
      writeError("Unknown command: \(command)\n\n")
      printHelp()
      exit(2)
    }
  }

  private static func doctor(json: Bool) async {
    var checks: [DoctorCheck] = []

    #if os(macOS)
      checks.append(DoctorCheck(name: "platform", status: "ok", detail: "macOS"))
    #else
      checks.append(
        DoctorCheck(
          name: "platform", status: "warn", detail: "Native AgentKeyBox UI/broker requires macOS."))
    #endif

    if let helper = MCPExecutableLocator.locate() {
      checks.append(DoctorCheck(name: "mcp-helper", status: "ok", detail: helper))
    } else {
      checks.append(
        DoctorCheck(name: "mcp-helper", status: "fail", detail: "agentkeybox-mcp not found."))
    }

    let tokenStore = BrokerTokenStore()
    if let token = try? tokenStore.load(), token.count >= 32 {
      checks.append(
        DoctorCheck(name: "broker-auth", status: "ok", detail: "Local broker token exists."))
    } else {
      checks.append(
        DoctorCheck(
          name: "broker-auth", status: "warn",
          detail: "Open AgentKeyBox once to initialize local broker authentication."))
    }

    #if os(macOS)
      do {
        let response = try await LocalBrokerClient(timeoutSeconds: 2).send(
          BrokerRequest(
            action: .listCredentials,
            agentID: "akb-doctor",
            agentDisplayName: "AgentKeyBox Doctor",
            projectPath: FileManager.default.currentDirectoryPath
          ))
        let count = response.credentials?.count ?? 0
        checks.append(
          DoctorCheck(
            name: "broker", status: "ok",
            detail: "AgentKeyBox broker responded; \(count) credential(s) visible here."))
      } catch {
        checks.append(
          DoctorCheck(name: "broker", status: "warn", detail: error.localizedDescription))
      }
    #else
      checks.append(
        DoctorCheck(name: "broker", status: "skip", detail: "Broker check only runs on macOS."))
    #endif

    await appendAgentCheck(ClaudeCodeAdapter(), to: &checks)
    await appendAgentCheck(CodexAdapter(), to: &checks)

    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      if let data = try? encoder.encode(checks), let text = String(data: data, encoding: .utf8) {
        print(text)
      }
    } else {
      print("AgentKeyBox doctor")
      for check in checks {
        let icon: String
        switch check.status {
        case "ok": icon = "✓"
        case "fail": icon = "✗"
        case "warn": icon = "!"
        default: icon = "-"
        }
        print("\(icon) \(check.name): \(check.detail)")
      }
    }

    if checks.contains(where: { $0.status == "fail" }) {
      exit(1)
    }
  }

  private static func appendAgentCheck<A: AgentAdapter>(
    _ adapter: A, to checks: inout [DoctorCheck]
  ) async {
    let status = await adapter.integrationStatus()
    switch status {
    case .notInstalled:
      checks.append(
        DoctorCheck(
          name: adapter.id, status: "skip", detail: "\(adapter.displayName) is not installed."))
    case .notConfigured:
      checks.append(
        DoctorCheck(
          name: adapter.id, status: "warn",
          detail: "Installed, but AgentKeyBox MCP is not configured."))
    case .configured:
      checks.append(
        DoctorCheck(name: adapter.id, status: "ok", detail: "AgentKeyBox MCP is configured."))
    case .error:
      checks.append(
        DoctorCheck(
          name: adapter.id, status: "warn", detail: "Could not determine integration status."))
    }
  }

  private static func connect(target: String, helper: String) async {
    let normalized = target.lowercased()
    var failures = 0

    if normalized == "claude" || normalized == "all" {
      do {
        try await ClaudeCodeAdapter().installIntegration(mcpExecutablePath: helper)
        print("✓ Connected Claude Code")
      } catch {
        failures += 1
        writeError("✗ Claude Code: \(error.localizedDescription)\n")
      }
    }

    if normalized == "codex" || normalized == "all" {
      do {
        try await CodexAdapter().installIntegration(mcpExecutablePath: helper)
        print("✓ Connected Codex")
      } catch {
        failures += 1
        writeError("✗ Codex: \(error.localizedDescription)\n")
      }
    }

    if !["claude", "codex", "all"].contains(normalized) {
      writeError("Unknown agent: \(target). Use claude, codex, or all.\n")
      exit(2)
    }
    if failures > 0 { exit(1) }
  }

  private static func argumentValue(_ flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
      return nil
    }
    return args[index + 1]
  }

  private static func writeError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
  }

  private static func printHelp() {
    print(
      """
      AgentKeyBox CLI (akb)

      Usage:
        akb doctor [--json]             Check local installation and agent integrations
        akb status [--json]             Alias for doctor
        akb connect claude              Configure Claude Code MCP integration
        akb connect codex               Configure Codex MCP integration
        akb connect all                 Configure both supported agents
        akb helper-path                 Print the discovered agentkeybox-mcp path
        akb help
      """)
  }
}
