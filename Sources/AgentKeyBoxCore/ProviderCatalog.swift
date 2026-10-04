import Foundation

public struct ProviderPreset: Identifiable, Codable, Hashable, Sendable {
  public let id: String
  public let displayName: String
  public let environmentKeys: [String]
  public let defaultKind: CredentialKind
  /// Default `http_request` allowlist for credentials of this provider.
  public let allowedHosts: [String]
  /// Where the user creates or copies this provider's key.
  public let dashboardURL: String?

  public init(
    id: String,
    displayName: String,
    environmentKeys: [String],
    defaultKind: CredentialKind = .apiKey,
    allowedHosts: [String] = [],
    dashboardURL: String? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.environmentKeys = environmentKeys
    self.defaultKind = defaultKind
    self.allowedHosts = allowedHosts
    self.dashboardURL = dashboardURL
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
      dashboardURL: "https://supabase.com/dashboard/project/_/settings/api-keys"),
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
      environmentKeys: ["APP_STORE_CONNECT_API_KEY", "ASC_KEY_ID"], defaultKind: .p8,
      allowedHosts: ["api.appstoreconnect.apple.com"],
      dashboardURL: "https://appstoreconnect.apple.com/access/integrations/api"),
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
