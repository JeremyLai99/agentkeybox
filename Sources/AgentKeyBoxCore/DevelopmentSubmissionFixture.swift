#if DEBUG && os(macOS)
  import Foundation
  import Security

  /// Synthetic endpoint acceptance only. Release builds contain none of this configuration,
  /// certificate pin, seed data or status export. Native approval/authentication are unchanged.
  public struct DevelopmentSubmissionFixture: Sendable {
    public struct Configuration: Codable, Sendable {
      public let profileID: UUID
      public let port: Int
    }

    private static let codes = (1...8).map { String(format: "fixture-submit-code-%03d", $0) }
    public let profile: DevelopmentProfile
    public let configuration: Configuration
    private let certificateData: Data
    public var origin: String { "https://127.0.0.1:\(configuration.port)" }

    public static func load(profile: DevelopmentProfile) throws -> Self? {
      let path = profile.file("submission-fixture.json")
      guard FileManager.default.fileExists(atPath: path.path) else { return nil }
      let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: path))
      guard configuration.profileID == profile.id, (1024...65535).contains(configuration.port)
      else {
        throw SensitiveDataError.invalidDestination
      }
      let certificateData = try Data(contentsOf: profile.file("fixture-cert.der"))
      guard SecCertificateCreateWithData(nil, certificateData as CFData) != nil else {
        throw SensitiveDataError.invalidDestination
      }
      return Self(profile: profile, configuration: configuration, certificateData: certificateData)
    }

    public func seed(store: KeychainSecretStore, metadata: MetadataStore) throws {
      guard !store.usesDataProtectionKeychain else { throw SensitiveDataError.invalidPayload }
      if !FileManager.default.fileExists(atPath: profile.file("metadata.json").path) {
        let card = SensitivePayload(
          card: try StoredCard(
            number: "4242424242424242", cardholder: "AKB synthetic card fixture",
            expirationMonth: 12, expirationYear: 2099))
        let codes = SensitivePayload(
          recoveryCodes: try RecoveryCodeSet(text: Self.codes.joined(separator: "\n")))
        let cardItem = CredentialMetadata(
          id: profile.fixtureID(1), label: "QA — Local synthetic card",
          service: "Synthetic submission fixture", kind: .creditCard,
          submissionURL: origin + "/submit/card", payloadRevision: card.revision)
        let codeItem = CredentialMetadata(
          id: profile.fixtureID(2), label: "QA — Local submission codes",
          service: "Synthetic submission fixture", kind: .recoveryCodes,
          submissionURL: origin + "/submit/recovery", payloadRevision: codes.revision)
        try store.save(secret: card.encoded(), id: cardItem.id)
        try store.save(secret: codes.encoded(), id: codeItem.id)
        try metadata.save(MetadataSnapshot(credentials: [cardItem, codeItem]))
      }
      try recordStoredState(store: store, metadata: metadata)
      try Data(UUID().uuidString.utf8).write(
        to: profile.file("submission-boot-id"), options: .atomic)
    }

    /// Phase-only evidence, never authentication reasons or grants.
    public static func recordAuthenticationPhase(_ phase: String) {
      guard let profile = DevelopmentProfile.current,
        FileManager.default.fileExists(atPath: profile.file("submission-fixture.json").path)
      else { return }
      try? Data(phase.utf8).write(to: profile.file("submission-auth-phase"), options: .atomic)
    }

    /// A one-shot, bounded crash-test window after the native editor persisted metadata.
    /// Only the known synthetic card can reach this DEBUG hook; no secret has been changed yet.
    public static func pauseBeforeSecretSave(id: UUID) throws {
      guard let profile = DevelopmentProfile.current, id == profile.fixtureID(1),
        try load(profile: profile) != nil,
        FileManager.default.fileExists(atPath: profile.file("interrupt-card-save").path)
      else { return }
      try FileManager.default.removeItem(at: profile.file("interrupt-card-save"))
      try Data("metadataSaved".utf8).write(
        to: profile.file("submission-save-phase"), options: .atomic)
      // If the external client fails to kill its verified QA PID, the ordinary transaction
      // restores the original metadata after this bounded wait.
      Thread.sleep(forTimeInterval: 10)
      throw SensitiveDataError.invalidPayload
    }

    public func recordStoredState(store: KeychainSecretStore, metadata: MetadataStore) throws {
      try recordStoredStatuses(store: store)
      guard let cardData = try store.read(id: profile.fixtureID(1)),
        let codeData = try store.read(id: profile.fixtureID(2))
      else { throw SensitiveDataError.invalidPayload }
      let card = try SensitivePayload.decode(cardData, kind: .creditCard)
      let codes = try SensitivePayload.decode(codeData, kind: .recoveryCodes)
      guard card.card?.number == "4242424242424242",
        card.card?.cardholder == "AKB synthetic card fixture",
        card.card?.expirationMonth == 12, card.card?.expirationYear == 2099
      else { throw SensitiveDataError.invalidPayload }
      let items = metadata.load().credentials
      let evidence: [String: String] = [
        "cardPayloadRevision": card.revision.uuidString,
        "cardRevisionMatches": String(
          items.first { $0.id == profile.fixtureID(1) }?.payloadRevision == card.revision),
        "codeRevisionMatches": String(
          items.first { $0.id == profile.fixtureID(2) }?.payloadRevision == codes.revision),
        "codeGeneration": codes.recoveryCodes!.generation.uuidString,
      ]
      try JSONEncoder().encode(evidence).write(
        to: profile.file("submission-storage.json"), options: .atomic)
    }

    public func recordStoredStatuses(store: KeychainSecretStore) throws {
      guard !store.usesDataProtectionKeychain,
        let data = try store.read(id: profile.fixtureID(2)),
        let codes = try SensitivePayload.decode(data, kind: .recoveryCodes).recoveryCodes,
        codes.entries.map(\.value) == Self.codes
      else { throw SensitiveDataError.invalidPayload }
      try JSONEncoder().encode(codes.entries.map { $0.status.rawValue }).write(
        to: profile.file("submission-statuses.json"), options: .atomic)
    }

    func validate(_ credential: CredentialMetadata) throws {
      let path: String
      switch (credential.id, credential.kind) {
      case (profile.fixtureID(1), .creditCard): path = "/submit/card"
      case (profile.fixtureID(2), .recoveryCodes): path = "/submit/recovery"
      default: throw SensitiveDataError.invalidDestination
      }
      guard credential.submissionURL == origin + path else {
        throw SensitiveDataError.invalidDestination
      }
    }

    func accepts(_ request: URLRequest) -> Bool {
      request.url?.absoluteString == origin + "/submit/card"
        || request.url?.absoluteString == origin + "/submit/recovery"
    }

    func disposition(_ challenge: URLAuthenticationChallenge)
      -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
      guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
        challenge.protectionSpace.host == "127.0.0.1",
        challenge.protectionSpace.port == configuration.port,
        let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
        let trust = challenge.protectionSpace.serverTrust,
        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
        let leaf = chain.first, SecCertificateCopyData(leaf) as Data == certificateData
      else { return (.cancelAuthenticationChallenge, nil) }
      SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
      SecTrustSetAnchorCertificatesOnly(trust, true)
      guard SecTrustEvaluateWithError(trust, nil) else {
        return (.cancelAuthenticationChallenge, nil)
      }
      return (.useCredential, URLCredential(trust: trust))
    }
  }
#endif
