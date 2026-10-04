import Foundation

#if os(macOS)
  import LocalAuthentication
  import Security

  /// Stores secrets in the data protection keychain, guarded by user presence (Touch ID or the
  /// login password), when the app is team-signed with a `keychain-access-groups` entitlement.
  ///
  /// Reading with the `AuthenticationGrant` from the approval prompt reuses that authentication,
  /// so one approval costs exactly one Touch ID. Access is bound to the team's access group, not
  /// to a per-build code signature, so rebuilding the app never triggers keychain password prompts.
  ///
  /// Ad-hoc / unsigned development builds cannot use the data protection keychain
  /// (`errSecMissingEntitlement`) and fall back to the legacy file-based keychain, whose access
  /// control is tied to the exact build and therefore prompts for the login password after each
  /// rebuild.
  public final class KeychainSecretStore: SecretStore, Sendable {
    private let service: String
    public let usesDataProtectionKeychain: Bool

    public init(service: String = "dev.agentkeybox.secrets") {
      self.service = service
      self.usesDataProtectionKeychain = Self.dataProtectionKeychainAvailable(service: service)
    }

    public func save(secret: Data, id: UUID) throws {
      guard usesDataProtectionKeychain else {
        try saveLegacy(secret: secret, id: id)
        return
      }

      // Access control cannot be changed by SecItemUpdate, so replace the item.
      try deleteItem(baseQuery(id: id, dataProtection: true))

      var error: Unmanaged<CFError>?
      guard
        let accessControl = SecAccessControlCreateWithFlags(
          nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error)
      else {
        throw SecretStoreError.unexpectedStatus(errSecParam)
      }
      var add = baseQuery(id: id, dataProtection: true)
      add[kSecValueData as String] = secret
      add[kSecAttrAccessControl as String] = accessControl
      let status = SecItemAdd(add as CFDictionary, nil)
      guard status == errSecSuccess else {
        throw SecretStoreError.unexpectedStatus(status)
      }
    }

    public func read(id: UUID) throws -> Data? {
      try read(id: id, grant: nil)
    }

    /// Without a grant, the keychain shows its own user-presence prompt.
    public func read(id: UUID, grant: AuthenticationGrant?) throws -> Data? {
      guard usesDataProtectionKeychain else {
        return try copyData(baseQuery(id: id, dataProtection: false))
      }

      var query = baseQuery(id: id, dataProtection: true)
      if let grant {
        query[kSecUseAuthenticationContext as String] = grant.context
      }
      if let data = try copyData(query) {
        return data
      }
      return try migrateFromLegacy(id: id)
    }

    public func delete(id: UUID) throws {
      if usesDataProtectionKeychain {
        try deleteItem(baseQuery(id: id, dataProtection: true))
      }
      try deleteItem(baseQuery(id: id, dataProtection: false))
    }

    /// Moves an item created by an older build into the data protection keychain. Reading the
    /// legacy item may prompt for the login password one last time.
    private func migrateFromLegacy(id: UUID) throws -> Data? {
      guard let data = try copyData(baseQuery(id: id, dataProtection: false)) else {
        return nil
      }
      try save(secret: data, id: id)
      try? deleteItem(baseQuery(id: id, dataProtection: false))
      return data
    }

    private func saveLegacy(secret: Data, id: UUID) throws {
      let query = baseQuery(id: id, dataProtection: false)
      let update: [String: Any] = [kSecValueData as String: secret]
      let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

      if status == errSecItemNotFound {
        var add = query
        add[kSecValueData as String] = secret
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
          throw SecretStoreError.unexpectedStatus(addStatus)
        }
      } else if status != errSecSuccess {
        throw SecretStoreError.unexpectedStatus(status)
      }
    }

    private func baseQuery(id: UUID, dataProtection: Bool) -> [String: Any] {
      // Always set the flag explicitly. Without it, macOS SecItemDelete also removes matching
      // data protection items, so deleting the legacy copy after migration deleted the new one.
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: id.uuidString,
        kSecUseDataProtectionKeychain as String: dataProtection,
      ]
    }

    private func copyData(_ base: [String: Any]) throws -> Data? {
      var query = base
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess else {
        throw SecretStoreError.unexpectedStatus(status)
      }
      return result as? Data
    }

    private func deleteItem(_ query: [String: Any]) throws {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw SecretStoreError.unexpectedStatus(status)
      }
    }

    /// Looks up a nonexistent item: an entitled build gets `errSecItemNotFound`, an unentitled
    /// one gets `errSecMissingEntitlement`. Never prompts.
    private static func dataProtectionKeychainAvailable(service: String) -> Bool {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "agentkeybox-capability-probe",
        kSecUseDataProtectionKeychain as String: true,
      ]
      return SecItemCopyMatching(query as CFDictionary, nil) != errSecMissingEntitlement
    }
  }
#else
  public final class KeychainSecretStore: SecretStore, Sendable {
    public let usesDataProtectionKeychain = false
    public init(service: String = "dev.agentkeybox.secrets") {}
    public func save(secret: Data, id: UUID) throws { throw SecretStoreError.unsupportedPlatform }
    public func read(id: UUID) throws -> Data? { throw SecretStoreError.unsupportedPlatform }
    public func read(id: UUID, grant: AuthenticationGrant?) throws -> Data? {
      throw SecretStoreError.unsupportedPlatform
    }
    public func delete(id: UUID) throws { throw SecretStoreError.unsupportedPlatform }
  }
#endif
