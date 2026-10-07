import Foundation

/// The short status lines on a key's card. Kept in Core so the wording is tested.
public enum CredentialCardText {
  /// "Used by Claude Code · 2 min ago", or "Not used yet".
  public static func usage(_ lastUse: AccessEvent?, now: Date = Date()) -> String {
    guard let lastUse else { return "Not used yet" }
    return "Used by \(lastUse.agentDisplayName) · \(relative(lastUse.timestamp, now: now))"
  }

  /// Something the user should fix, or nil when the key needs no attention. Only text keys can
  /// be sent by `http_request`, so file credentials never get the "any website" notice.
  public static func attention(for credential: CredentialMetadata) -> String? {
    guard !credential.isFileCredential else { return nil }
    let hosts = (credential.allowedHosts ?? []).filter { !$0.isEmpty }
    return hosts.isEmpty ? "Can be sent to any website" : nil
  }

  static func relative(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "just now"
    case ..<3600: return "\(Int(seconds / 60)) min ago"
    case ..<86_400: return "\(Int(seconds / 3600)) hr ago"
    case ..<172_800: return "yesterday"
    default:
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.setLocalizedDateFormatFromTemplate("MMM d")
      return formatter.string(from: date)
    }
  }
}
