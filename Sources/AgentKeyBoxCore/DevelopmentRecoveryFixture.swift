#if DEBUG && os(macOS)
  import Foundation
  import WebKit

  /// Synthetic native acceptance only. No selector, certificate pin or state export ships.
  /// The runner creates this config inside an isolated profile before starting the QA app.
  public struct DevelopmentRecoveryFixture: Sendable {
    public struct Configuration: Codable, Sendable {
      public let profileID: UUID
      public let port: Int
    }

    private static let codes = (1...4).map { String(format: "fixture-recovery-%03d", $0) }

    public let profile: DevelopmentProfile
    public let configuration: Configuration
    private let certificateData: Data
    public var origin: String { "https://127.0.0.1:\(configuration.port)" }
    public var loginURL: String { origin + "/login-recovery" }
    public var recoveryURL: String { origin + "/recover" }

    public static func load(profile: DevelopmentProfile) throws -> Self? {
      let file = profile.file("recovery-fixture.json")
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }
      let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file))
      guard config.profileID == profile.id, (1024...65535).contains(config.port) else {
        throw ControlledBrowserError.unavailable
      }
      let certificate = try Data(contentsOf: profile.file("fixture-cert.der"))
      guard SecCertificateCreateWithData(nil, certificate as CFData) != nil else {
        throw ControlledBrowserError.unavailable
      }
      return Self(profile: profile, configuration: config, certificateData: certificate)
    }

    /// Called only against the QA service. Existing data is loaded, never re-seeded on restart.
    public func seed(store: KeychainSecretStore, metadata: MetadataStore) throws {
      guard !store.usesDataProtectionKeychain else { throw ControlledBrowserError.unavailable }
      if !FileManager.default.fileExists(atPath: profile.file("metadata.json").path) {
        let login = SensitivePayload(
          login: try StoredLogin(username: "fixture-user", password: "synthetic-password-42!"))
        let codes = SensitivePayload(
          recoveryCodes: try RecoveryCodeSet(text: Self.codes.joined(separator: "\n")))
        let loginItem = CredentialMetadata(
          id: profile.id, label: "QA — Local recovery login", service: "Synthetic loopback fixture",
          kind: .login, loginURL: loginURL, payloadRevision: login.revision)
        let codeItem = CredentialMetadata(
          id: profile.fixtureID(2), label: "QA — Local recovery codes",
          service: "Synthetic loopback fixture", kind: .recoveryCodes,
          linkedLoginID: loginItem.id,
          recoveryCodeCounts: codes.recoveryCodes.map(RecoveryCodeCounts.init(codes:)),
          payloadRevision: codes.revision)
        try store.save(secret: login.encoded(), id: loginItem.id)
        try store.save(secret: codes.encoded(), id: codeItem.id)
        try metadata.save(MetadataSnapshot(credentials: [loginItem, codeItem]))
      }
      try recordStoredStatuses(store: store)
      try Data(UUID().uuidString.utf8).write(to: profile.file("recovery-boot-id"), options: .atomic)
    }

    /// Phase-only evidence for cancellation tests, never reasons, grants or secret values.
    public static func recordAuthenticationPhase(_ phase: String) {
      guard let profile = DevelopmentProfile.current,
        FileManager.default.fileExists(atPath: profile.file("recovery-fixture.json").path)
      else { return }
      try? Data(phase.utf8).write(to: profile.file("recovery-auth-phase"), options: .atomic)
    }

    /// Acceptance evidence contains statuses only, read back from the isolated Keychain.
    /// The server records whether this durable snapshot existed before the recovery POST.
    public func recordStoredStatuses(store: KeychainSecretStore) throws {
      guard !store.usesDataProtectionKeychain,
        let data = try store.read(id: profile.fixtureID(2)),
        let codes = try SensitivePayload.decode(data, kind: .recoveryCodes).recoveryCodes,
        codes.entries.map(\.value) == Self.codes
      else { throw ControlledBrowserError.unavailable }
      let statuses = codes.entries.map { $0.status.rawValue }
      try JSONEncoder().encode(statuses).write(
        to: profile.file("recovery-statuses.json"), options: .atomic)
    }

    @MainActor
    public func browser(credential: CredentialMetadata, owner: BrowserOwner) throws
      -> ControlledBrowserSession
    {
      guard credential.id == profile.id, credential.loginURL == loginURL else {
        throw ControlledBrowserError.unavailable
      }
      return try PinnedRecoveryFixtureBrowser(
        credential: credential, owner: owner, certificateData: certificateData,
        port: configuration.port)
    }
  }

  @MainActor
  private final class PinnedRecoveryFixtureBrowser: ControlledBrowserSession {
    private let certificateData: Data
    private let port: Int

    init(credential: CredentialMetadata, owner: BrowserOwner, certificateData: Data, port: Int)
      throws
    {
      self.certificateData = certificateData
      self.port = port
      try super.init(credential: credential, owner: owner)
    }

    override func webView(
      _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
      completionHandler:
        @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
      guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
        challenge.protectionSpace.host == "127.0.0.1", challenge.protectionSpace.port == port,
        let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
        let trust = challenge.protectionSpace.serverTrust,
        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
        let leaf = chain.first,
        SecCertificateCopyData(leaf) as Data == certificateData
      else {
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      // Scoped to this challenge: no Keychain/system trust change or accept-any-certificate path.
      SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
      SecTrustSetAnchorCertificatesOnly(trust, true)
      guard SecTrustEvaluateWithError(trust, nil) else {
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      completionHandler(.useCredential, URLCredential(trust: trust))
    }
  }
#endif
