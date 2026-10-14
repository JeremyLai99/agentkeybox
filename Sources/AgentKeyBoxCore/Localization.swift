import Foundation

/// The language the user picked in Settings. `system` follows macOS.
public enum LanguagePreference: String, CaseIterable, Identifiable, Sendable {
  case system
  case english = "en"
  case traditionalChinese = "zh-Hant"

  public var id: String { rawValue }

  /// Each language is named in itself, so it can be found whatever the current language is.
  public var displayName: String {
    switch self {
    case .system: return L("Same as macOS")
    case .english: return "English"
    case .traditionalChinese: return "繁體中文"
    }
  }
}

/// A language AgentKeyBox shows its interface in.
public enum AppLanguage: String, Sendable {
  case english = "en"
  case traditionalChinese = "zh-Hant"

  public var locale: Locale {
    Locale(identifier: self == .english ? "en_US" : "zh_Hant_TW")
  }

  /// Traditional Chinese for Taiwan, Hong Kong, and Macau, and for `zh-Hant`; English otherwise.
  public static func matching(preferredLanguages: [String]) -> AppLanguage {
    guard let first = preferredLanguages.first?.lowercased() else { return .english }
    let traditional = ["zh-hant", "zh-tw", "zh-hk", "zh-mo"]
    return traditional.contains(where: { first.hasPrefix($0) }) ? .traditionalChinese : .english
  }
}

/// Where the chosen language is stored. The app, the `akb` CLI, and the MCP helper all read the
/// app's preferences, so the terminal speaks the same language as the window.
public enum Localization {
  public static let preferencesDomain = "dev.agentkeybox.app"
  static let preferenceKey = "AgentKeyBoxLanguage"

  private final class Override: @unchecked Sendable {
    let lock = NSLock()
    var language: AppLanguage?
  }
  private static let override = Override()

  /// Forces a language regardless of preferences (tests use English).
  public static func setOverride(_ language: AppLanguage?) {
    override.lock.lock()
    override.language = language
    override.lock.unlock()
  }

  static var defaults: UserDefaults {
    // Inside the app, its own domain is `.standard`; naming it as a suite is not allowed.
    Bundle.main.bundleIdentifier == preferencesDomain
      ? .standard : UserDefaults(suiteName: preferencesDomain) ?? .standard
  }

  public static var preference: LanguagePreference {
    get {
      defaults.string(forKey: preferenceKey).flatMap(LanguagePreference.init(rawValue:)) ?? .system
    }
    set {
      if newValue == .system {
        defaults.removeObject(forKey: preferenceKey)
      } else {
        defaults.set(newValue.rawValue, forKey: preferenceKey)
      }
    }
  }

  public static var current: AppLanguage {
    override.lock.lock()
    let forced = override.language
    override.lock.unlock()
    if let forced { return forced }
    switch preference {
    case .english: return .english
    case .traditionalChinese: return .traditionalChinese
    case .system: return AppLanguage.matching(preferredLanguages: systemLanguages)
    }
  }

  /// The user's macOS languages. `AppleLanguages` set for this app only (to localize the
  /// system-provided menus) is ignored, so "Same as macOS" really follows macOS.
  static var systemLanguages: [String] {
    UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"]
      as? [String] ?? Locale.preferredLanguages
  }
}

/// Text in the current interface language. The English text is the key; a missing translation
/// falls back to English.
public func L(_ english: String) -> String {
  switch Localization.current {
  case .english: return english
  case .traditionalChinese: return Translations.traditionalChinese[english] ?? english
  }
}

/// Text with `%@` placeholders filled in, in the current interface language. Translations may
/// reorder placeholders with `%1$@`, `%2$@`.
public func L(_ english: String, _ arguments: CVarArg...) -> String {
  String(format: L(english), locale: Localization.current.locale, arguments: arguments)
}
