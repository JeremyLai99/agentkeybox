/// The release version, shown to agents by the MCP helper. Keep in sync with the repository's
/// `VERSION` file, which the release scripts read for the app bundle and zip name; a test checks
/// that the two match.
public enum AgentKeyBoxVersion {
  public static let current = "0.4.0"
}
