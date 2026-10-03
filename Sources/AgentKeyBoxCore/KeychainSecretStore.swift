import Foundation

#if os(macOS)
  import Security

  public final class KeychainSecretStore: SecretStore, Sendable {
    private let service: String

    public init(service: String = "dev.agentkeybox.secrets") {
      self.service = service
    }

    public func save(secret: Data, id: UUID) throws {
      let account = id.uuidString
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]

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

    public func read(id: UUID) throws -> Data? {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: id.uuidString,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]

      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess else {
        throw SecretStoreError.unexpectedStatus(status)
      }
      return result as? Data
    }

    public func delete(id: UUID) throws {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: id.uuidString,
      ]
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw SecretStoreError.unexpectedStatus(status)
      }
    }
  }
#else
  public final class KeychainSecretStore: SecretStore, Sendable {
    public init(service: String = "dev.agentkeybox.secrets") {}
    public func save(secret: Data, id: UUID) throws { throw SecretStoreError.unsupportedPlatform }
    public func read(id: UUID) throws -> Data? { throw SecretStoreError.unsupportedPlatform }
    public func delete(id: UUID) throws { throw SecretStoreError.unsupportedPlatform }
  }
#endif
