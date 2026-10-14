import Foundation

/// Keeps coding agents connected wherever AgentKeyBox.app lives.
///
/// Agents store the MCP helper's path. Pointing them into the app bundle broke the connection
/// whenever the app moved: macOS runs a downloaded app from a random read-only copy
/// (App Translocation) until it is moved, and users drag the app to Applications after trying
/// it. Agents therefore get a copy of the helper at a fixed path in AgentKeyBox's support
/// directory, refreshed from the app on every launch.
public enum HelperInstaller {
  /// `~/Library/Application Support/AgentKeyBox/bin/agentkeybox-mcp`.
  public static var installedHelperURL: URL {
    BrokerEndpoint.defaultSocketURL.deletingLastPathComponent()
      .appendingPathComponent("bin", isDirectory: true)
      .appendingPathComponent("agentkeybox-mcp")
  }

  /// Copies `source` to `destination` unless it is already identical, replacing it atomically
  /// so a running agent keeps its old copy. Returns the destination path.
  @discardableResult
  public static func install(from source: URL, to destination: URL = installedHelperURL) throws
    -> String
  {
    let fm = FileManager.default
    if source.standardizedFileURL.path == destination.standardizedFileURL.path {
      return destination.path
    }
    let data = try Data(contentsOf: source)
    if let existing = try? Data(contentsOf: destination), existing == data,
      fm.isExecutableFile(atPath: destination.path)
    {
      return destination.path
    }
    let directory = destination.deletingLastPathComponent()
    try fm.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // Written fresh rather than copied, so no quarantine attribute comes along; the helper's
    // code signature is embedded in the binary and stays valid.
    let temporary = directory.appendingPathComponent(".agentkeybox-mcp-\(UUID().uuidString)")
    try data.write(to: temporary)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
    if fm.fileExists(atPath: destination.path) {
      _ = try fm.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try fm.moveItem(at: temporary, to: destination)
    }
    return destination.path
  }

  /// Installs the helper found next to the running app or CLI and returns the fixed path agents
  /// should use, or nil when no helper can be found.
  public static func installBundledHelper() -> String? {
    guard let bundled = MCPExecutableLocator.locate(includingInstalled: false) else {
      return FileManager.default.isExecutableFile(atPath: installedHelperURL.path)
        ? installedHelperURL.path : nil
    }
    return try? install(from: URL(fileURLWithPath: bundled))
  }
}

/// Where the running app is, and whether it should offer to move to Applications.
public enum InstallLocation {
  /// macOS runs a quarantined app that has not been moved from a random, read-only path.
  public static func isTranslocated(_ bundleURL: URL) -> Bool {
    bundleURL.path.contains("/AppTranslocation/")
  }

  public static func isInApplications(_ bundleURL: URL, home: URL = FileManager.default
    .homeDirectoryForCurrentUser) -> Bool
  {
    let path = bundleURL.standardizedFileURL.path
    return path.hasPrefix("/Applications/")
      || path.hasPrefix(home.standardizedFileURL.appendingPathComponent("Applications").path + "/")
  }

  /// Only a real `.app` bundle outside Applications is offered the move; `swift run` is not.
  public static func shouldOfferMove(_ bundleURL: URL) -> Bool {
    bundleURL.pathExtension == "app" && !isInApplications(bundleURL)
  }

  /// `/Applications` when it can be written, otherwise `~/Applications`.
  public static func applicationsDirectory(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
    return FileManager.default.isWritableFile(atPath: system.path)
      ? system : home.appendingPathComponent("Applications", isDirectory: true)
  }
}

#if canImport(Darwin)
  import Darwin

  extension InstallLocation {
    /// Copies the app bundle into place, replacing an older copy there (moved to the Trash by
    /// default). The quarantine attribute is removed from the copy: the user already opened
    /// this notarized app, and a still-quarantined copy that Finder did not move would be
    /// translocated again.
    public static func copyApp(
      from source: URL, to destination: URL,
      removingExisting remove: (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
      }
    ) throws {
      let fm = FileManager.default
      try fm.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if fm.fileExists(atPath: destination.path) {
        try remove(destination)
      }
      try fm.copyItem(at: source, to: destination)
      removeQuarantine(from: destination)
    }

    static func removeQuarantine(from root: URL) {
      var paths = [root.path]
      if let walker = FileManager.default.enumerator(atPath: root.path) {
        while let relative = walker.nextObject() as? String {
          paths.append(root.appendingPathComponent(relative).path)
        }
      }
      for path in paths {
        removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
      }
    }
  }
#endif
