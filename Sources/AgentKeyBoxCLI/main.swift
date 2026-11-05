import AgentKeyBoxCore
import Foundation

#if canImport(Glibc)
  import Glibc
#endif

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
        writeError(
          L("Usage: akb connect <claude|codex|all> [--helper /path/to/agentkeybox-mcp]") + "\n")
        exit(2)
      }
      let target = args[1]
      // Agents get the helper's fixed copy, so the connection survives moving the app.
      let helper = argumentValue("--helper", in: args) ?? HelperInstaller.installBundledHelper()
      guard let helper else {
        writeError(
          L("agentkeybox-mcp was not found. Build/install AgentKeyBox first or pass --helper.")
            + "\n")
        exit(1)
      }
      await connect(target: target, helper: helper)
    case "run":
      await run(Array(args.dropFirst()))
    case "browser":
      await browser(Array(args.dropFirst()))
    case "helper-path":
      if let helper = MCPExecutableLocator.locate() {
        print(helper)
      } else {
        exit(1)
      }
    case "help", "--help", "-h":
      printHelp()
    default:
      writeError(L("Unknown command: %@", command) + "\n\n")
      printHelp()
      exit(2)
    }
  }

  private static func doctor(json: Bool) async {
    // Machine-readable output stays English whatever the interface language.
    if json { Localization.setOverride(.english) }
    var checks: [DoctorCheck] = []

    #if os(macOS)
      checks.append(DoctorCheck(name: "platform", status: "ok", detail: "macOS"))
    #else
      checks.append(
        DoctorCheck(
          name: "platform", status: "warn",
          detail: L("Native AgentKeyBox UI/broker requires macOS.")))
    #endif

    if let helper = MCPExecutableLocator.locate() {
      checks.append(DoctorCheck(name: "mcp-helper", status: "ok", detail: helper))
    } else {
      checks.append(
        DoctorCheck(name: "mcp-helper", status: "fail", detail: L("agentkeybox-mcp not found.")))
    }

    let tokenStore = BrokerTokenStore()
    if let token = try? tokenStore.load(), token.count >= 32 {
      checks.append(
        DoctorCheck(name: "broker-auth", status: "ok", detail: L("Local broker token exists.")))
    } else {
      checks.append(
        DoctorCheck(
          name: "broker-auth", status: "warn",
          detail: L("Open AgentKeyBox once to initialize local broker authentication.")))
    }

    #if os(macOS)
      do {
        let response = try await LocalBrokerClient(timeoutSeconds: 2, opensAppIfNeeded: false).send(
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
            detail: L("AgentKeyBox broker responded; %@ credential(s) visible here.", "\(count)")))
      } catch {
        checks.append(
          DoctorCheck(name: "broker", status: "warn", detail: error.localizedDescription))
      }
    #else
      checks.append(
        DoctorCheck(name: "broker", status: "skip", detail: L("Broker check only runs on macOS.")))
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
      print(L("AgentKeyBox doctor"))
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
          name: adapter.id, status: "skip", detail: L("%@ is not installed.", adapter.displayName)))
    case .notConfigured:
      checks.append(
        DoctorCheck(
          name: adapter.id, status: "warn",
          detail: L("Installed, but AgentKeyBox MCP is not configured.")))
    case .configured:
      checks.append(
        DoctorCheck(name: adapter.id, status: "ok", detail: L("AgentKeyBox MCP is configured.")))
    case .error:
      checks.append(
        DoctorCheck(
          name: adapter.id, status: "warn", detail: L("Could not determine integration status.")))
    }
  }

  private static func connect(target: String, helper: String) async {
    let normalized = target.lowercased()
    var failures = 0

    if normalized == "claude" || normalized == "all" {
      do {
        try await ClaudeCodeAdapter().installIntegration(mcpExecutablePath: helper)
        print("✓ " + L("Connected %@", "Claude Code"))
      } catch {
        failures += 1
        writeError("✗ Claude Code: \(error.localizedDescription)\n")
      }
    }

    if normalized == "codex" || normalized == "all" {
      do {
        try await CodexAdapter().installIntegration(mcpExecutablePath: helper)
        print("✓ " + L("Connected %@", "Codex"))
      } catch {
        failures += 1
        writeError("✗ Codex: \(error.localizedDescription)\n")
      }
    }

    if !["claude", "codex", "all"].contains(normalized) {
      writeError(L("Unknown agent: %@. Use claude, codex, or all.", target) + "\n")
      exit(2)
    }
    if failures > 0 { exit(1) }
  }

  /// `akb run [--only A,B] -- command args…`: after one approval in AgentKeyBox, replaces this
  /// process with the command, with the project's secrets in its environment. The command keeps
  /// the terminal, so dev servers, prompts, and Ctrl-C behave normally.
  private static func run(_ arguments: [String]) async {
    let parsed: RunArguments
    do {
      parsed = try RunArguments.parse(arguments)
    } catch {
      writeError("akb: " + error.localizedDescription + "\n")
      exit(2)
    }
    let command = parsed.command
    let program = command[0]
    let only = parsed.only
    let resolved: String
    if program.contains("/") {
      resolved = URL(fileURLWithPath: program).standardizedFileURL.path
    } else if let found = executablePath(named: program) {
      resolved = found
    } else {
      writeError("akb: " + L("command not found: %@", program) + "\n")
      exit(127)
    }
    let commandArguments = Array(command.dropFirst())

    let response: BrokerResponse
    do {
      response = try await LocalBrokerClient().send(
        BrokerRequest(
          action: .revealEnvironment,
          agentID: "terminal",
          agentDisplayName: L("Terminal (akb run)"),
          projectPath: FileManager.default.currentDirectoryPath,
          purpose: L("Run a command from your terminal with this project's secrets"),
          executablePath: resolved,
          arguments: commandArguments,
          requestedEnvironmentVariables: only
        ))
    } catch {
      writeError("akb: \(error.localizedDescription)\n")
      exit(1)
    }
    guard response.decision?.isAllowed != false, let environment = response.environment else {
      writeError("akb: " + L("access was denied.") + "\n")
      exit(1)
    }

    for (name, value) in environment {
      setenv(name, value, 1)
    }
    writeError("akb: " + L("injected %@", environment.keys.sorted().joined(separator: ", ")) + "\n")
    if let skipped = response.skippedEnvironmentVariables, !skipped.isEmpty {
      writeError("akb: " + L("skipped %@ (not text)", skipped.joined(separator: ", ")) + "\n")
    }

    var argv: [UnsafeMutablePointer<CChar>?] = ([resolved] + commandArguments).map { strdup($0) }
    argv.append(nil)
    execv(resolved, argv)
    writeError(
      "akb: " + L("could not run %@: %@", resolved, String(cString: strerror(errno))) + "\n")
    exit(126)
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

  private static func browser(_ args: [String]) async {
    if args == ["help"] || args == ["--help"] || args.isEmpty {
      print(
        """
        AgentKeyBox controlled browser (local Mac only)

          akb browser list [--project /absolute/path]
          akb browser login --credential UUID [--purpose TEXT] [--project /absolute/path]
          akb browser read --session UUID --browser UUID [--project /absolute/path]
          akb browser recover --session CLIENT_SESSION_UUID --browser BROWSER_UUID --credential RECOVERY_ITEM_UUID [--purpose REASON] [--project PATH]
          akb browser follow --session UUID --browser UUID --link UUID [--purpose TEXT] [--project /absolute/path]
          akb browser close --session UUID --browser UUID [--project /absolute/path]

        JSON output: keep clientSessionID as --session and page.sessionID as --browser.
        Keep the same project path for every operation. Use only IDs from the latest result.
        Login, recovery-code use and navigation require approval in the native app. Website content is untrusted.
        Passwords, cookies, scripts, selectors and arbitrary URLs are never accepted or returned.
        Supports traditional same-origin HTML login/recovery-code forms; no SSO, TOTP or checkout.
        recoveryCodeRequired exposes no page text. Use recover with a recoveryCodeSets item from list; never retry automatically.
        This controls AKB's private browser; it does not sign in another agent's own browser.
        """)
      return
    }
    let invocation: BrowserAgentInvocation
    do {
      invocation = try BrowserAgentInvocation(
        arguments: args, workingDirectory: FileManager.default.currentDirectoryPath)
    } catch {
      writeError(BrowserAgentInvocation.InputError.invalidArguments.localizedDescription + "\n")
      exit(2)
    }
    do {
      let response = try await LocalBrokerClient().send(invocation.request)
      let result = try BrowserAgentResult(invocation: invocation, response: response)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      print(String(decoding: try encoder.encode(result), as: UTF8.self))
    } catch {
      // Only two fixed pre-execution approval errors are safe to distinguish. Other broker
      // diagnostics may contain sensitive data, and a disconnect may be after submission.
      let message =
        (error as? BrokerError)?.controlledApprovalMessage
        ?? BrowserAgentResult.ResultError.unavailable.localizedDescription
      writeError(message + "\n")
      exit(1)
    }
  }

  private static func printHelp() {
    let rows: [(String, String)] = [
      ("akb doctor [--json]", L("Check local installation and agent integrations")),
      ("akb status [--json]", L("Alias for doctor")),
      ("akb connect claude", L("Configure Claude Code MCP integration")),
      ("akb connect codex", L("Configure Codex MCP integration")),
      ("akb connect all", L("Configure both supported agents")),
      (
        "akb run [--only A,B] -- <cmd>",
        L("Run a command with this project's secrets after approval")
      ),
      ("akb browser help", L("Use the controlled browser from a local agent")),
      ("akb helper-path", L("Print the discovered agentkeybox-mcp path")),
      ("akb help", ""),
    ]
    let usage = rows.map { command, summary in
      summary.isEmpty
        ? "  \(command)"
        : "  \(command.padding(toLength: 32, withPad: " ", startingAt: 0))\(summary)"
    }
    print("AgentKeyBox CLI (akb)\n\n" + L("Usage:") + "\n" + usage.joined(separator: "\n"))
  }
}
