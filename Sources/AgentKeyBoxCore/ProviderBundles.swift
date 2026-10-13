import Foundation

/// A provider key and the non-secret settings it is used with (an App Store Connect key with its
/// Key ID and Issuer ID, a Supabase key with its project URL) are one thing to the user: one
/// card, one editor, and one set of variables when an approved command runs.
public enum ProviderBundles {
  /// Required settings that are missing, and settings whose value does not look right.
  public static func settingsNeedingAttention(for credential: CredentialMetadata)
    -> (missing: [ProviderSetting], invalid: [ProviderSetting])
  {
    guard let preset = ProviderCatalog.preset(for: credential) else { return ([], []) }
    var missing: [ProviderSetting] = []
    var invalid: [ProviderSetting] = []
    for setting in preset.settings {
      let value = credential.settings?[setting.variable] ?? ""
      if value.isEmpty {
        if setting.required { missing.append(setting) }
      } else if !setting.isValid(value) {
        invalid.append(setting)
      }
    }
    return (missing, invalid)
  }

  /// "Includes Key ID and Issuer ID" for a key that carries settings.
  public static func includes(for credential: CredentialMetadata) -> String? {
    includes(settings: credential.settings ?? [:])
  }

  /// "Includes Project URL and Anon key", in the provider's order, or nil without settings.
  public static func includes(settings: [String: String]) -> String? {
    let present = ProviderCatalog.all.flatMap(\.settings).filter {
      !(settings[$0.variable] ?? "").isEmpty
    }
    guard !present.isEmpty else { return nil }
    return "Includes " + listed(present.map(\.label))
  }

  /// Settings to set next to the key when an approved command runs. Names that are not safe to
  /// inject, or that would replace the key's own variable, are left out.
  public static func environment(for credential: CredentialMetadata, excluding keyVariable: String?)
    -> [String: String]
  {
    var environment: [String: String] = [:]
    for (name, value) in credential.settings ?? [:]
    where !value.isEmpty && name != keyVariable
      && ApprovedCommandRunner.isAllowedInjectionTarget(name)
    {
      environment[name] = value
    }
    return environment
  }

  /// Settings for a scanned key: values from the project's `.env` files under any name the
  /// provider uses, and the App Store Connect Key ID from an `AuthKey_<ID>.p8` file name.
  /// Also returns the `.env` names the values came from.
  static func settings(
    for preset: ProviderPreset, keyID: String?, envValues: [String: String]
  ) -> (settings: [String: String], usedNames: Set<String>) {
    var settings: [String: String] = [:]
    var used = Set<String>()
    for setting in preset.settings {
      let present = setting.names.filter { !(envValues[$0] ?? "").isEmpty }
      if let first = present.first { settings[setting.variable] = envValues[first] }
      used.formUnion(present)
    }
    if let keyID, preset.settings.contains(where: { $0.variable == "ASC_KEY_ID" }) {
      settings["ASC_KEY_ID"] = keyID
    }
    return (settings, used)
  }

  /// Fills settings that a key saved before bundles existed can get without asking: the Key ID
  /// of an App Store Connect key, from its label or file name.
  public static func migrated(_ credential: CredentialMetadata) -> CredentialMetadata {
    guard credential.kind == .p8, ProviderCatalog.preset(for: credential)?.id == "apple",
      (credential.settings?["ASC_KEY_ID"] ?? "").isEmpty
    else { return credential }
    let prefix = "App Store Connect key "
    let keyID =
      credential.label.hasPrefix(prefix)
      ? String(credential.label.dropFirst(prefix.count))
      : ProjectScanner.appStoreConnectKeyID(fromFileName: credential.label)
    guard let keyID, !keyID.isEmpty else { return credential }
    var updated = credential
    updated.settings = (credential.settings ?? [:]).merging(["ASC_KEY_ID": keyID]) { $1 }
    return updated
  }

  /// "Key ID", "Key ID and Issuer ID", "A, B, and C".
  public static func listed(_ items: [String]) -> String {
    switch items.count {
    case 0: return ""
    case 1: return items[0]
    case 2: return "\(items[0]) and \(items[1])"
    default: return items.dropLast().joined(separator: ", ") + ", and " + (items.last ?? "")
    }
  }
}
