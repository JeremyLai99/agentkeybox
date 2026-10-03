import Foundation

public struct ProviderPreset: Identifiable, Codable, Hashable, Sendable {
  public let id: String
  public let displayName: String
  public let environmentKeys: [String]
  public let defaultKind: CredentialKind

  public init(
    id: String,
    displayName: String,
    environmentKeys: [String],
    defaultKind: CredentialKind = .apiKey
  ) {
    self.id = id
    self.displayName = displayName
    self.environmentKeys = environmentKeys
    self.defaultKind = defaultKind
  }
}

public enum ProviderCatalog {
  public static let all: [ProviderPreset] = [
    ProviderPreset(id: "openai", displayName: "OpenAI", environmentKeys: ["OPENAI_API_KEY"]),
    ProviderPreset(
      id: "anthropic", displayName: "Anthropic", environmentKeys: ["ANTHROPIC_API_KEY"]),
    ProviderPreset(
      id: "stripe", displayName: "Stripe", environmentKeys: ["STRIPE_SECRET_KEY", "STRIPE_API_KEY"]),
    ProviderPreset(
      id: "supabase", displayName: "Supabase",
      environmentKeys: ["SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_ANON_KEY"]),
    ProviderPreset(
      id: "github", displayName: "GitHub", environmentKeys: ["GITHUB_TOKEN", "GH_TOKEN"],
      defaultKind: .token),
    ProviderPreset(
      id: "google", displayName: "Google / Gemini",
      environmentKeys: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]),
    ProviderPreset(
      id: "firebase", displayName: "Firebase", environmentKeys: ["GOOGLE_APPLICATION_CREDENTIALS"],
      defaultKind: .json),
    ProviderPreset(
      id: "apple", displayName: "Apple App Store Connect",
      environmentKeys: ["APP_STORE_CONNECT_API_KEY", "ASC_KEY_ID"], defaultKind: .p8),
    ProviderPreset(
      id: "vercel", displayName: "Vercel", environmentKeys: ["VERCEL_TOKEN"], defaultKind: .token),
    ProviderPreset(id: "resend", displayName: "Resend", environmentKeys: ["RESEND_API_KEY"]),
    ProviderPreset(
      id: "cloudflare", displayName: "Cloudflare",
      environmentKeys: ["CLOUDFLARE_API_TOKEN", "CF_API_TOKEN"], defaultKind: .token),
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
}
