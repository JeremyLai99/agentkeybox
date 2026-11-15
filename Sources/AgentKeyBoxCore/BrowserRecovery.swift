import Foundation

/// Only the native user selects the login or exact endpoint. The agent cannot supply a URL.
public enum BrowserRecoveryPolicy {
  public static func validate(
    _ credential: CredentialMetadata, target: URL, origin: String,
    login: CredentialMetadata? = nil
  ) throws {
    guard credential.kind == .recoveryCodes,
      BrowserPolicy.permits(target, origin: origin)
    else { throw ControlledBrowserError.unavailable }
    if let linkedLoginID = credential.linkedLoginID {
      guard let login, login.kind == .login, login.id == linkedLoginID,
        login.projectID == credential.projectID,
        let url = try? BrowserPolicy.loginURL(login.loginURL),
        BrowserPolicy.origin(url) == origin
      else { throw ControlledBrowserError.unavailable }
    } else {
      guard (try? SensitiveSubmissionPolicy.destination(credential.submissionURL)) == target else {
        throw ControlledBrowserError.unavailable
      }
    }
  }

  public static func logins(
    in credentials: [CredentialMetadata], projectID: UUID?
  ) -> [CredentialMetadata] {
    credentials.filter {
      $0.kind == .login && $0.projectID == projectID
        && (try? BrowserPolicy.loginURL($0.loginURL)) != nil
    }
  }

  /// Fixed guidance only; no challenge-page text or form fields are returned.
  public static func recoveryPage(
    sessionID: UUID, origin: String, target: URL, login: CredentialMetadata,
    candidates: [CredentialMetadata]
  ) -> BrowserPage {
    let hasMatch = candidates.contains {
      (try? validate($0, target: target, origin: origin, login: login)) != nil
    }
    return BrowserPage(
      sessionID: sessionID, status: "recoveryCodeRequired", origin: origin,
      title: L("Recovery code required"),
      text: hasMatch
        ? L(
          "Request browser_recover with a recovery-code item whose for_login matches this login, or whose submission URL exactly matches. A separate native approval is required. No page content is available until verification completes."
        )
        : L(
          "Ask the user to add recovery codes in AgentKeyBox and link them to this website login. No page content is available until verification completes."
        ),
      links: [])
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
