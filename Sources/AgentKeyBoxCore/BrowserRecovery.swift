import Foundation

/// The stored endpoint is a user-controlled boundary, not a URL supplied by the agent/page.
public enum BrowserRecoveryPolicy {
  public static func validate(_ credential: CredentialMetadata, target: URL, origin: String) throws
  {
    guard credential.kind == .recoveryCodes,
      try SensitiveSubmissionPolicy.destination(credential.submissionURL) == target,
      BrowserPolicy.permits(target, origin: origin)
    else { throw ControlledBrowserError.unavailable }
  }

  /// Must run synchronously after approval and revision checks, before a browser fill/POST.
  /// Even an uncertain result leaves the saved entry issued; agents cannot reset it.
  public static func reserve(
    payload: SensitivePayload, credential: CredentialMetadata,
    persist: (Data) throws -> Void
  ) throws -> String {
    var validated = try SensitivePayload.decode(payload.encoded(), kind: .recoveryCodes)
    guard credential.kind == .recoveryCodes, validated.revision == credential.payloadRevision,
      var codes = validated.recoveryCodes
    else { throw SensitiveDataError.invalidPayload }
    let code = try codes.reserveNext()
    validated.recoveryCodes = codes
    validated.revision = UUID()
    try persist(validated.encoded())
    return code
  }
}
