import Foundation

#if os(macOS)
  import Darwin
#else
  import Glibc
#endif

/// A diagnostic snapshot, never an authorization check. Both executable entry points force
/// `atLaunch` before doing any work; even clients created later reuse that original snapshot.
public struct ExecutableIdentity: Sendable {
  public static let atLaunch: ExecutableIdentity? = {
    #if os(macOS)
      // dyld supplies the executable path independently of argv[0] or the agent's environment.
      var size: UInt32 = 0
      _ = _NSGetExecutablePath(nil, &size)
      var path = [CChar](repeating: 0, count: Int(size))
      guard _NSGetExecutablePath(&path, &size) == 0 else { return nil }
      let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      guard let executablePath = String(bytes: bytes, encoding: .utf8) else { return nil }
      return ExecutableIdentity(url: URL(fileURLWithPath: executablePath))
    #else
      return ExecutableIdentity(
        url: URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath())
    #endif
  }()

  private struct Metadata: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init?(path: String) {
      var info = stat()
      // stat follows symlinks, identifying the executable rather than the symlink itself.
      guard stat(path, &info) == 0 else { return nil }
      device = UInt64(info.st_dev)
      inode = UInt64(info.st_ino)
      size = Int64(info.st_size)
      #if os(macOS)
        let modified = info.st_mtimespec
        let changed = info.st_ctimespec
      #else
        let modified = info.st_mtim
        let changed = info.st_ctim
      #endif
      modifiedSeconds = Int64(modified.tv_sec)
      modifiedNanoseconds = Int64(modified.tv_nsec)
      changedSeconds = Int64(changed.tv_sec)
      changedNanoseconds = Int64(changed.tv_nsec)
    }
  }

  private let path: String
  private let metadata: Metadata

  init?(url: URL) {
    // Anchor relative paths now, but retain symlinks so retargeting one is also detected.
    let path = url.standardizedFileURL.path
    guard let metadata = Metadata(path: path) else { return nil }
    self.path = path
    self.metadata = metadata
  }

  var hasChanged: Bool {
    // Missing/inaccessible files are inconclusive: keep the broker's original rejection.
    guard let current = Metadata(path: path) else { return false }
    return current != metadata
  }
}

public enum BrokerClientKind: Equatable, Sendable {
  case mcpHelper
  case commandLine

  var updatedMessage: String {
    switch self {
    case .mcpHelper:
      return L(
        "AgentKeyBox was updated, but this agent is still using the old connection. Reconnect the agentkeybox MCP server (in Claude Code: /mcp → agentkeybox → Reconnect), or restart your agent, then try again."
      )
    case .commandLine:
      return L("AgentKeyBox was updated. Run this command again.")
    }
  }

  func rejectionError(message: String, executable: ExecutableIdentity?) -> BrokerError {
    // Do not inspect the file for unrelated failures, or use this diagnostic to retry a request.
    guard message == "Requests must come from the AgentKeyBox helper or akb.",
      executable?.hasChanged == true
    else { return .requestFailed(message) }
    return .clientUpdated(self)
  }
}
