import Foundation

/// Which programs may talk to the local broker.
///
/// The broker token only proves the caller runs as this user, which a coding agent with a
/// shell does too: it could read the token and send requests itself, with a made-up agent name
/// and command, or ask for `akb run`'s raw environment. A team-signed AgentKeyBox therefore
/// also checks the code signature of the connecting process: only AgentKeyBox's own helper and
/// `akb`, signed by the same team, may connect, and only `akb` may receive secrets for
/// `akb run`. Hardened runtime keeps those binaries from being injected into.
public enum BrokerPeerPolicy: Equatable, Sendable {
  /// Development builds without a team signature cannot verify callers.
  case unverified
  /// Callers must be signed by this team with one of the allowed identifiers.
  case signedBy(teamID: String)

  public static let helperIdentifier = "agentkeybox-mcp"
  public static let cliIdentifier = "akb"

  /// The calling program, as far as the broker could establish it.
  public struct Peer: Equatable, Sendable {
    public var teamID: String?
    public var identifier: String?
    /// The running code's signature is valid for this team's requirement.
    public var signatureValid: Bool

    public init(teamID: String?, identifier: String?, signatureValid: Bool) {
      self.teamID = teamID
      self.identifier = identifier
      self.signatureValid = signatureValid
    }
  }

  /// Nil when the peer may make this request; otherwise the reason it may not.
  public func rejection(of peer: Peer?, for action: BrokerAction) -> String? {
    guard case .signedBy(let teamID) = self else { return nil }
    guard let peer, peer.signatureValid, peer.teamID == teamID else {
      return "Requests must come from the AgentKeyBox helper or akb."
    }
    if action == .revealEnvironment {
      return peer.identifier == Self.cliIdentifier ? nil : "Only akb run can request this."
    }
    return [Self.helperIdentifier, Self.cliIdentifier].contains(peer.identifier ?? "")
      ? nil : "Requests must come from the AgentKeyBox helper or akb."
  }
}

#if os(macOS)
  import Darwin
  import Security

  extension BrokerPeerPolicy {
    /// Verifies callers when this process is signed by a team; otherwise `.unverified`.
    public static func forCurrentProcess() -> BrokerPeerPolicy {
      var code: SecCode?
      guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
        let teamID = signingInfo(of: code)?.teamID
      else { return .unverified }
      return .signedBy(teamID: teamID)
    }

    /// The program at the other end of a Unix-domain socket, identified by its audit token
    /// (not its PID, which can be reused).
    static func peer(ofSocket fd: Int32, teamID: String) -> Peer? {
      var token = audit_token_t()
      var length = socklen_t(MemoryLayout<audit_token_t>.size)
      guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return nil }
      let tokenData = withUnsafeBytes(of: &token) { Data($0) }
      var code: SecCode?
      let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
      guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
        let code
      else { return nil }

      let info = signingInfo(of: code)
      var requirement: SecRequirement?
      let text =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
      let valid =
        SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
        && requirement.map { SecCodeCheckValidity(code, [], $0) == errSecSuccess } == true
      return Peer(teamID: info?.teamID, identifier: info?.identifier, signatureValid: valid)
    }

    private static func signingInfo(of code: SecCode) -> (teamID: String?, identifier: String?)? {
      var staticCode: SecStaticCode?
      guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
        return nil
      }
      var info: CFDictionary?
      guard
        SecCodeCopySigningInformation(
          staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
        let dictionary = info as? [String: Any]
      else { return nil }
      return (
        dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
        dictionary[kSecCodeInfoIdentifier as String] as? String
      )
    }
  }
#endif
