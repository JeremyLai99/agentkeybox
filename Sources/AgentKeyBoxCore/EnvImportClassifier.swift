import Foundation

/// Suggests which `.env` entries are secrets, so importing a file does not turn `PORT=3000` or
/// `NODE_ENV=development` into Keychain items (whose short values would also make output
/// redaction mangle unrelated text).
public enum EnvImportClassifier {
  static let secretMarkers = [
    "KEY", "SECRET", "TOKEN", "PASSWORD", "PASSWD", "PRIVATE", "CREDENTIAL", "AUTH", "DSN",
    "SIGNING", "WEBHOOK",
  ]
  /// Prefixes frameworks use for values that are shipped to browsers on purpose.
  static let publicPrefixes = [
    "NEXT_PUBLIC_", "VITE_", "EXPO_PUBLIC_", "PUBLIC_", "REACT_APP_", "NUXT_PUBLIC_",
  ]
  static let publicMarkers = ["PUBLISHABLE", "ANON_KEY", "PUBLIC_KEY"]

  public static func looksSecret(key: String, value: String) -> Bool {
    let upper = key.uppercased()
    if publicPrefixes.contains(where: { upper.hasPrefix($0) })
      || publicMarkers.contains(where: { upper.contains($0) })
    {
      return false
    }
    if ProviderCatalog.all.contains(where: { $0.environmentKeys.contains(upper) }) {
      return true
    }
    if secretMarkers.contains(where: { upper.contains($0) }) {
      return true
    }
    // Connection strings with embedded credentials, e.g. postgres://user:password@host/db.
    if let components = URLComponents(string: value), components.password != nil {
      return true
    }
    return false
  }
}
