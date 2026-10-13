import Foundation

/// A non-secret value a provider's key needs next to it, such as the Issuer ID of an App Store
/// Connect key. The key and its settings show as one card.
public struct ProviderSetting: Codable, Hashable, Sendable {
  /// Variable name it is stored and injected under, e.g. `ASC_ISSUER_ID`.
  public let variable: String
  /// Plain-language name for the editor, e.g. "Issuer ID".
  public let label: String
  /// Other names projects use for the same value, e.g. `NEXT_PUBLIC_SUPABASE_URL`.
  public let aliases: [String]
  /// A key without a required setting is flagged on its card.
  public let required: Bool
  /// What a valid value looks like, shown as the field's placeholder.
  public let example: String
  /// Regular expression a valid value matches.
  public let pattern: String
  /// Where the user finds the value.
  public let helpURL: String?

  public init(
    variable: String, label: String, aliases: [String] = [], required: Bool, example: String,
    pattern: String, helpURL: String? = nil
  ) {
    self.variable = variable
    self.label = label
    self.aliases = aliases
    self.required = required
    self.example = example
    self.pattern = pattern
    self.helpURL = helpURL
  }

  /// The setting's own name first, then its aliases.
  public var names: [String] { [variable] + aliases }

  public func isValid(_ value: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
  }
}

public struct ProviderPreset: Identifiable, Codable, Hashable, Sendable {
  public let id: String
  public let displayName: String
  public let environmentKeys: [String]
  public let defaultKind: CredentialKind
  /// Default `http_request` allowlist for credentials of this provider.
  public let allowedHosts: [String]
  /// Where the user creates or copies this provider's key.
  public let dashboardURL: String?
  /// Non-secret values the key is used with.
  public let settings: [ProviderSetting]

  public init(
    id: String,
    displayName: String,
    environmentKeys: [String],
    defaultKind: CredentialKind = .apiKey,
    allowedHosts: [String] = [],
    dashboardURL: String? = nil,
    settings: [ProviderSetting] = []
  ) {
    self.id = id
    self.displayName = displayName
    self.environmentKeys = environmentKeys
    self.defaultKind = defaultKind
    self.allowedHosts = allowedHosts
    self.dashboardURL = dashboardURL
    self.settings = settings
  }
}

public enum ProviderCatalog {
  public static let all: [ProviderPreset] = [
    ProviderPreset(
      id: "openai", displayName: "OpenAI", environmentKeys: ["OPENAI_API_KEY"],
      allowedHosts: ["api.openai.com"],
      dashboardURL: "https://platform.openai.com/api-keys"),
    ProviderPreset(
      id: "anthropic", displayName: "Anthropic", environmentKeys: ["ANTHROPIC_API_KEY"],
      allowedHosts: ["api.anthropic.com"],
      dashboardURL: "https://console.anthropic.com/settings/keys"),
    ProviderPreset(
      id: "stripe", displayName: "Stripe", environmentKeys: ["STRIPE_SECRET_KEY", "STRIPE_API_KEY"],
      allowedHosts: ["api.stripe.com"],
      dashboardURL: "https://dashboard.stripe.com/apikeys"),
    ProviderPreset(
      id: "supabase", displayName: "Supabase",
      environmentKeys: ["SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_ANON_KEY"],
      allowedHosts: ["*.supabase.co"],
      dashboardURL: "https://supabase.com/dashboard/project/_/settings/api-keys",
      settings: [
        ProviderSetting(
          variable: "SUPABASE_URL", label: "Project URL",
          aliases: frameworkPublicNames("SUPABASE_URL"), required: true,
          example: "https://abcdefgh.supabase.co", pattern: #"^https://\S+$"#,
          helpURL: "https://supabase.com/dashboard/project/_/settings/api"),
        ProviderSetting(
          variable: "SUPABASE_ANON_KEY", label: "Anon key",
          aliases: frameworkPublicNames("SUPABASE_ANON_KEY"), required: false,
          example: "eyJhbGciOi…", pattern: #"^\S+$"#,
          helpURL: "https://supabase.com/dashboard/project/_/settings/api-keys"),
      ]),
    ProviderPreset(
      id: "github", displayName: "GitHub", environmentKeys: ["GITHUB_TOKEN", "GH_TOKEN"],
      defaultKind: .token, allowedHosts: ["api.github.com"],
      dashboardURL: "https://github.com/settings/personal-access-tokens"),
    ProviderPreset(
      id: "google", displayName: "Google / Gemini",
      environmentKeys: ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
      allowedHosts: ["generativelanguage.googleapis.com"],
      dashboardURL: "https://aistudio.google.com/apikey"),
    ProviderPreset(
      id: "firebase", displayName: "Firebase", environmentKeys: ["GOOGLE_APPLICATION_CREDENTIALS"],
      defaultKind: .json,
      dashboardURL: "https://console.firebase.google.com/project/_/settings/serviceaccounts/adminsdk"),
    ProviderPreset(
      id: "apple", displayName: "Apple App Store Connect",
      environmentKeys: ["APP_STORE_CONNECT_API_KEY"], defaultKind: .p8,
      allowedHosts: ["api.appstoreconnect.apple.com"],
      dashboardURL: "https://appstoreconnect.apple.com/access/integrations/api",
      settings: [
        ProviderSetting(
          variable: "ASC_KEY_ID", label: "Key ID",
          aliases: ["APP_STORE_CONNECT_KEY_ID", "APP_STORE_CONNECT_API_KEY_KEY_ID"],
          required: true, example: "ABC123DEF4", pattern: "^[A-Z0-9]{10}$",
          helpURL: "https://appstoreconnect.apple.com/access/integrations/api"),
        ProviderSetting(
          variable: "ASC_ISSUER_ID", label: "Issuer ID",
          aliases: ["APP_STORE_CONNECT_ISSUER_ID", "APP_STORE_CONNECT_API_KEY_ISSUER_ID"],
          required: true, example: "69a6de70-03db-47e3-e053-5b8c7c11a4d1",
          pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
          helpURL: "https://appstoreconnect.apple.com/access/integrations/api"),
      ]),
    ProviderPreset(
      id: "vercel", displayName: "Vercel", environmentKeys: ["VERCEL_TOKEN"], defaultKind: .token,
      allowedHosts: ["api.vercel.com"],
      dashboardURL: "https://vercel.com/account/settings/tokens"),
    ProviderPreset(
      id: "resend", displayName: "Resend", environmentKeys: ["RESEND_API_KEY"],
      allowedHosts: ["api.resend.com"],
      dashboardURL: "https://resend.com/api-keys"),
    ProviderPreset(
      id: "cloudflare", displayName: "Cloudflare",
      environmentKeys: ["CLOUDFLARE_API_TOKEN", "CF_API_TOKEN"], defaultKind: .token,
      allowedHosts: ["api.cloudflare.com"],
      dashboardURL: "https://dash.cloudflare.com/profile/api-tokens"),
  ]

  /// `SUPABASE_URL` plus the browser-exposed copies frameworks require, e.g.
  /// `NEXT_PUBLIC_SUPABASE_URL`.
  static func frameworkPublicNames(_ name: String) -> [String] {
    ["NEXT_PUBLIC_", "VITE_", "EXPO_PUBLIC_", "PUBLIC_", "REACT_APP_", "NUXT_PUBLIC_"].map {
      $0 + name
    }
  }

  /// The setting a variable name stands for, if any provider uses it as one.
  public static func setting(named name: String) -> ProviderSetting? {
    let upper = name.uppercased()
    for preset in all {
      if let match = preset.settings.first(where: { $0.names.contains(upper) }) { return match }
    }
    return nil
  }

  /// The provider a stored key belongs to.
  public static func preset(for credential: CredentialMetadata) -> ProviderPreset? {
    preset(matchingService: credential.service, environmentKey: credential.environmentVariableName)
  }

  public static func inferService(fromEnvironmentKey key: String) -> String {
    let upper = key.uppercased()
    if let match = all.first(where: { preset in
      preset.environmentKeys.contains(where: { $0 == upper })
    }) {
      return match.displayName
    }

    let prefixRules: [(String, String)] = [
      ("OPENAI_", "OpenAI"),
      ("ANTHROPIC_", "Anthropic"),
      ("STRIPE_", "Stripe"),
      ("SUPABASE_", "Supabase"),
      ("GITHUB_", "GitHub"),
      ("GH_", "GitHub"),
      ("GEMINI_", "Google / Gemini"),
      ("GOOGLE_", "Google / Gemini"),
      ("FIREBASE_", "Firebase"),
      ("VERCEL_", "Vercel"),
      ("RESEND_", "Resend"),
      ("CLOUDFLARE_", "Cloudflare"),
      ("CF_", "Cloudflare"),
    ]
    if let match = prefixRules.first(where: { upper.hasPrefix($0.0) }) {
      return match.1
    }
    return key.split(separator: "_").first.map { String($0).capitalized } ?? "Imported"
  }

  public static func preset(id: String) -> ProviderPreset? {
    all.first { $0.id == id }
  }

  /// The preset whose service name or environment keys match, used to prefill allowlists and
  /// dashboard links for imported or agent-requested credentials.
  public static func preset(matchingService service: String?, environmentKey key: String?)
    -> ProviderPreset?
  {
    if let key {
      let inferred = inferService(fromEnvironmentKey: key)
      if let match = all.first(where: { $0.displayName == inferred }) { return match }
    }
    if let service {
      return all.first {
        $0.displayName.caseInsensitiveCompare(service) == .orderedSame
          || $0.id.caseInsensitiveCompare(service) == .orderedSame
      }
    }
    return nil
  }
}
