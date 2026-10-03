import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public enum SecretDeliveryMode: String, Codable, CaseIterable, Sendable {
  case environment
  case tempFile
}

public enum CommandRunnerError: Error, LocalizedError, Equatable {
  case executableMustBeAbsolute
  case executableNotFound
  case invalidEnvironmentVariable
  case invalidWorkingDirectory
  case outputFileUnavailable
  case secretNotUTF8
  case executionTimedOut
  case temporarySecretFileUnavailable

  public var errorDescription: String? {
    switch self {
    case .executableMustBeAbsolute:
      return "The approved executable path must be absolute."
    case .executableNotFound:
      return "The approved executable does not exist or is not executable."
    case .invalidEnvironmentVariable:
      return "The requested environment variable name is invalid."
    case .invalidWorkingDirectory:
      return "The requested project directory does not exist."
    case .outputFileUnavailable:
      return "AgentKeyBox could not capture command output."
    case .secretNotUTF8:
      return
        "This credential cannot be injected directly as text. Use temporary-file delivery instead."
    case .executionTimedOut:
      return "The approved command exceeded AgentKeyBox's execution timeout."
    case .temporarySecretFileUnavailable:
      return "AgentKeyBox could not create a protected temporary credential file."
    }
  }
}

public struct CommandExecutionResult: Codable, Hashable, Sendable {
  public var exitCode: Int32
  public var output: String
  public var outputTruncated: Bool

  public init(exitCode: Int32, output: String, outputTruncated: Bool = false) {
    self.exitCode = exitCode
    self.output = output
    self.outputTruncated = outputTruncated
  }
}

public enum SecretRedactor {
  public static func redact(_ text: String, secretData: Data) -> String {
    guard !secretData.isEmpty else { return text }

    var candidates: Set<String> = []
    if let raw = String(data: secretData, encoding: .utf8), !raw.isEmpty {
      candidates.insert(raw)

      if let encoded = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
        encoded != raw
      {
        candidates.insert(encoded)
      }

      if let json = try? JSONEncoder().encode(raw),
        let jsonString = String(data: json, encoding: .utf8),
        jsonString.count >= 2
      {
        candidates.insert(String(jsonString.dropFirst().dropLast()))
      }
    }
    candidates.insert(secretData.base64EncodedString())
    let hex = secretData.map { String(format: "%02x", $0) }.joined()
    candidates.insert(hex)
    candidates.insert(hex.uppercased())

    return
      candidates
      .filter { !$0.isEmpty }
      .sorted { $0.count > $1.count }
      .reduce(text) { partial, candidate in
        partial.replacingOccurrences(of: candidate, with: "[REDACTED_BY_AGENTKEYBOX]")
      }
  }
}

public enum ApprovedCommandRunner {
  public static func run(
    executablePath: String,
    arguments: [String],
    workingDirectory: String,
    environmentVariable: String,
    secretData: Data,
    deliveryMode: SecretDeliveryMode = .environment,
    maxOutputBytes: Int = 128 * 1024,
    timeoutSeconds: TimeInterval = 60
  ) throws -> CommandExecutionResult {
    guard executablePath.hasPrefix("/") else {
      throw CommandRunnerError.executableMustBeAbsolute
    }
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
      throw CommandRunnerError.executableNotFound
    }
    guard isValidEnvironmentVariable(environmentVariable) else {
      throw CommandRunnerError.invalidEnvironmentVariable
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw CommandRunnerError.invalidWorkingDirectory
    }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentKeyBox-output-\(UUID().uuidString)")
    _ = FileManager.default.createFile(
      atPath: outputURL.path,
      contents: nil,
      attributes: [.posixPermissions: 0o600]
    )
    defer { try? FileManager.default.removeItem(at: outputURL) }

    guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
      throw CommandRunnerError.outputFileUnavailable
    }

    var tempSecretDirectory: URL?
    var environment = safeBaseEnvironment()

    switch deliveryMode {
    case .environment:
      guard let value = String(data: secretData, encoding: .utf8) else {
        try? outputHandle.close()
        throw CommandRunnerError.secretNotUTF8
      }
      environment[environmentVariable] = value

    case .tempFile:
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentKeyBox-secret-\(UUID().uuidString)", isDirectory: true)
      do {
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]
        )
        let secretURL = directory.appendingPathComponent("credential")
        try secretData.write(to: secretURL, options: [.atomic])
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: secretURL.path)
        tempSecretDirectory = directory
        environment[environmentVariable] = secretURL.path
      } catch {
        try? outputHandle.close()
        try? FileManager.default.removeItem(at: directory)
        throw CommandRunnerError.temporarySecretFileUnavailable
      }
    }

    defer {
      if let tempSecretDirectory {
        try? FileManager.default.removeItem(at: tempSecretDirectory)
      }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    process.environment = environment
    process.standardOutput = outputHandle
    process.standardError = outputHandle

    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in semaphore.signal() }

    do {
      try process.run()
    } catch {
      try? outputHandle.close()
      throw error
    }

    let waitResult = semaphore.wait(timeout: .now() + timeoutSeconds)
    if waitResult == .timedOut {
      if process.isRunning {
        process.terminate()
        let terminated = semaphore.wait(timeout: .now() + 2)
        if terminated == .timedOut, process.isRunning {
          _ = kill(process.processIdentifier, SIGKILL)
          _ = semaphore.wait(timeout: .now() + 2)
        }
      }
      try? outputHandle.synchronize()
      try? outputHandle.close()
      throw CommandRunnerError.executionTimedOut
    }

    try? outputHandle.synchronize()
    try? outputHandle.close()

    let reader = try FileHandle(forReadingFrom: outputURL)
    defer { try? reader.close() }
    let data = try reader.read(upToCount: maxOutputBytes + 1) ?? Data()
    let truncated = data.count > maxOutputBytes
    let visible = truncated ? Data(data.prefix(maxOutputBytes)) : data
    let decoded = String(decoding: visible, as: UTF8.self)
    let redacted = SecretRedactor.redact(decoded, secretData: secretData)
    let suffix = truncated ? "\n[OUTPUT_TRUNCATED_BY_AGENTKEYBOX]" : ""

    return CommandExecutionResult(
      exitCode: process.terminationStatus,
      output: redacted + suffix,
      outputTruncated: truncated
    )
  }

  public static func isValidEnvironmentVariable(_ value: String) -> Bool {
    guard let first = value.first, first == "_" || first.isLetter else { return false }
    return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
  }

  private static func safeBaseEnvironment() -> [String: String] {
    let source = ProcessInfo.processInfo.environment
    let allowed = [
      "PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "SHELL",
    ]
    var result: [String: String] = [:]
    for key in allowed {
      if let value = source[key] { result[key] = value }
    }
    if result["PATH"] == nil {
      result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }
    return result
  }
}
