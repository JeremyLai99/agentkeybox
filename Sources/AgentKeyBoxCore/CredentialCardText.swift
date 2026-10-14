import Foundation

/// The short status lines on a key's card. Kept in Core so the wording is tested.
public enum CredentialCardText {
  /// "Used by Claude Code · 2 min ago", or "Not used yet".
  public static func usage(_ lastUse: AccessEvent?, now: Date = Date()) -> String {
    guard let lastUse else { return L("Not used yet") }
    return L("Used by %@ · %@", lastUse.agentDisplayName, relative(lastUse.timestamp, now: now))
  }

  /// Something the user should fix on a key's card, and the button that fixes it.
  public struct Attention: Equatable, Sendable {
    public var message: String
    public var action: String
    /// The fix is under Advanced in the editor.
    public var opensAdvanced: Bool
  }

  /// What the user should fix first, or nil when the key needs no attention. A key that cannot
  /// be used without a setting (an App Store Connect key without its Issuer ID) comes first.
  /// Only text keys can be sent by `http_request`, so file credentials never get the
  /// "any website" notice.
  public static func attention(for credential: CredentialMetadata) -> Attention? {
    let settings = ProviderBundles.settingsNeedingAttention(for: credential)
    if !settings.missing.isEmpty {
      let names = settings.missing.map { L($0.label) }
      return Attention(
        message: L("Needs the %@", ProviderBundles.listed(names)),
        action: names.count == 1 ? L("Add %@…", names[0]) : L("Add Missing Details…"),
        opensAdvanced: false)
    }
    if let invalid = settings.invalid.first {
      return Attention(
        message: L("The %@ doesn't look right", L(invalid.label)), action: L("Fix %@…", L(invalid.label)),
        opensAdvanced: false)
    }
    guard !credential.isFileCredential else { return nil }
    let hosts = (credential.allowedHosts ?? []).filter { !$0.isEmpty }
    return hosts.isEmpty
      ? Attention(
        message: L("Can be sent to any website"), action: L("Limit to one website…"),
        opensAdvanced: true)
      : nil
  }

  static func relative(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return L("just now")
    case ..<3600: return L("%@ min ago", "\(Int(seconds / 60))")
    case ..<86_400: return L("%@ hr ago", "\(Int(seconds / 3600))")
    case ..<172_800: return L("yesterday")
    default:
      let formatter = DateFormatter()
      formatter.locale = Localization.current.locale
      formatter.setLocalizedDateFormatFromTemplate("MMMd")
      return formatter.string(from: date)
    }
  }
}
