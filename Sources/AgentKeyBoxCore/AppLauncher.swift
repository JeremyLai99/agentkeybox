import Foundation

/// Settings the app, the MCP helper, and `akb` share through the app's preferences domain.
public enum AppPreferences {
  static let opensWhenNeededKey = "AgentKeyBoxOpensWhenNeeded"

  /// Whether the MCP helper and `akb` open AgentKeyBox when it is not running. On by default.
  public static var opensAppWhenNeeded: Bool {
    get { Localization.defaults.object(forKey: opensWhenNeededKey) as? Bool ?? true }
    set { Localization.defaults.set(newValue, forKey: opensWhenNeededKey) }
  }
}

#if os(macOS)
  /// Opens AgentKeyBox for a coding agent that needs it, without bringing its window forward.
  public enum AppLauncher {
    public static let bundleIdentifier = "dev.agentkeybox.app"
    /// Tells the app it was opened for an agent (or at login), so it starts in the menu bar
    /// without showing its main window.
    public static let backgroundArgument = "--agentkeybox-background"

    /// Returns false when AgentKeyBox is not installed or could not be opened.
    public static func openInBackground() -> Bool {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = ["-g", "-b", bundleIdentifier, "--args", backgroundArgument]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
      } catch {
        return false
      }
      process.waitUntilExit()
      return process.terminationStatus == 0
    }
  }
#endif
