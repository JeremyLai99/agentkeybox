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
      return
        "The requested environment variable name is invalid or reserved (e.g. PATH, HOME, DYLD_*, LD_*)."
    case .invalidWorkingDirectory:
      return "The requested project directory does not exist."
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

  /// Extra bytes to capture beyond a visible limit so the longest encoded form of the secret
  /// (hex, twice the raw length, or JSON/percent escaping) is complete before redaction.
  public static func margin(for secretData: Data) -> Int {
    secretData.count * 6 + 64
  }

  /// Redacts the full captured text first, then cuts it to `maxBytes`. Truncating first would
  /// split a secret at the boundary and leak its prefix.
  public static func redactThenTruncate(
    _ data: Data, secretData: Data, maxBytes: Int
  ) -> (text: String, truncated: Bool) {
    let redacted = redact(String(decoding: data, as: UTF8.self), secretData: secretData)
    guard redacted.utf8.count > maxBytes else { return (redacted, false) }
    // A multi-byte character split at the cut becomes U+FFFD, which is harmless here.
    let visible = String(decoding: redacted.utf8.prefix(maxBytes), as: UTF8.self)
    return (visible + "\n[OUTPUT_TRUNCATED_BY_AGENTKEYBOX]", true)
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
    guard isAllowedInjectionTarget(environmentVariable) else {
      throw CommandRunnerError.invalidEnvironmentVariable
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw CommandRunnerError.invalidWorkingDirectory
    }

    var tempSecretDirectory: URL?
    var environment = safeBaseEnvironment()

    switch deliveryMode {
    case .environment:
      guard let value = String(data: secretData, encoding: .utf8) else {
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
        try? FileManager.default.removeItem(at: directory)
        throw CommandRunnerError.temporarySecretFileUnavailable
      }
    }

    defer {
      if let tempSecretDirectory {
        try? FileManager.default.removeItem(at: tempSecretDirectory)
      }
    }

    // Output goes through a pipe into memory, keeping only what can be shown plus a redaction
    // margin and discarding the rest, so a chatty command cannot fill the disk.
    let pipe = Pipe()
    let collector = OutputCollector(limit: maxOutputBytes + SecretRedactor.margin(for: secretData))
    let readerFinished = DispatchSemaphore(value: 0)
    let readHandle = pipe.fileHandleForReading
    DispatchQueue.global(qos: .userInitiated).async {
      while let chunk = try? readHandle.read(upToCount: 64 * 1024), !chunk.isEmpty {
        collector.append(chunk)
      }
      readerFinished.signal()
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    process.environment = environment
    process.standardOutput = pipe
    process.standardError = pipe

    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in semaphore.signal() }

    do {
      try process.run()
    } catch {
      try? pipe.fileHandleForWriting.close()
      throw error
    }
    // Only the child should hold the write end, so EOF arrives when it exits.
    try? pipe.fileHandleForWriting.close()

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
      throw CommandRunnerError.executionTimedOut
    }

    // A background grandchild may keep the pipe open; do not wait for it indefinitely.
    _ = readerFinished.wait(timeout: .now() + 2)
    let captured = collector.snapshot()
    let (text, truncated) = SecretRedactor.redactThenTruncate(
      captured.data, secretData: secretData, maxBytes: maxOutputBytes)

    return CommandExecutionResult(
      exitCode: process.terminationStatus,
      output: text,
      outputTruncated: truncated || captured.discardedBytes
    )
  }

  /// Portable names only: ASCII letters, digits, and underscores, not starting with a digit.
  public static func isValidEnvironmentVariable(_ value: String) -> Bool {
    let scalars = value.unicodeScalars
    guard let first = scalars.first, first == "_" || isASCIILetter(first) else { return false }
    return scalars.allSatisfy { $0 == "_" || isASCIILetter($0) || ("0"..."9").contains($0) }
  }

  /// Variables that control how the approved program or its runtime behaves. Putting a secret
  /// into them would break or subvert the command instead of configuring it.
  static let reservedVariables: Set<String> = [
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PWD", "OLDPWD", "TERM", "LANG", "IFS",
    "ENV", "BASH_ENV", "PS4", "PROMPT_COMMAND", "NODE_OPTIONS", "NODE_PATH", "PYTHONPATH",
    "PYTHONHOME", "PYTHONSTARTUP", "PERL5OPT", "PERL5LIB", "RUBYOPT", "RUBYLIB",
    "GIT_SSH_COMMAND", "GIT_EXEC_PATH",
  ]
  static let reservedPrefixes = ["DYLD_", "LD_", "LC_"]

  /// A valid name that is not reserved; the only names a credential may be injected as.
  public static func isAllowedInjectionTarget(_ name: String) -> Bool {
    guard isValidEnvironmentVariable(name) else { return false }
    let upper = name.uppercased()
    return !reservedVariables.contains(upper)
      && !reservedPrefixes.contains(where: { upper.hasPrefix($0) })
  }

  private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
    ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
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

/// Keeps the first `limit` bytes of a stream and counts whether anything was dropped.
private final class OutputCollector: @unchecked Sendable {
  private let limit: Int
  private let lock = NSLock()
  private var data = Data()
  private var dropped = false

  init(limit: Int) {
    self.limit = limit
  }

  func append(_ chunk: Data) {
    lock.withLock {
      let room = limit - data.count
      if chunk.count > room {
        if room > 0 { data.append(chunk.prefix(room)) }
        dropped = true
      } else {
        data.append(chunk)
      }
    }
  }

  func snapshot() -> (data: Data, discardedBytes: Bool) {
    lock.withLock { (data, dropped) }
  }
}
