import Foundation

/// What the approval prompt says, decided in one testable place.
///
/// The default view answers four questions in plain words: who is asking, for which key, in
/// which project, and why. Technical details stay collapsed unless something needs the user's
/// attention, in which case a warning leads and Deny becomes the default button.
public struct ApprovalPresentation: Equatable, Sendable {
  public struct Fact: Equatable, Sendable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
      self.label = label
      self.value = value
    }
  }

  public struct Warning: Equatable, Sendable {
    public var title: String
    public var message: String
  }

  public var headline: String
  public var subtitle: String?
  public var facts: [Fact]
  public var warning: Warning?
  /// Unusual requests show the command or URL without an extra click.
  public var detailsExpanded: Bool
  /// When true, Return denies; allowing needs a deliberate click.
  public var denyIsDefault: Bool
  /// For a host outside the key's list: offered as "Always allow <host> for this key".
  public var rememberableHost: String?

  public static func make(
    for request: AgentRequest,
    credential: CredentialMetadata?,
    projectName: String?,
    risk: CommandRiskAssessment?
  ) -> ApprovalPresentation {
    let agent = request.agentDisplayName
    let keyName = credential.map { $0.service.isEmpty ? $0.label : $0.service } ?? "a"
    let subtitle = projectName.map { "in \($0)" }
    var facts: [Fact] = []
    if let purpose = request.purpose, !purpose.isEmpty {
      facts.append(Fact("For", purpose))
    }

    switch request.kind {
    case .httpRequest:
      let host = request.url.flatMap { URLComponents(string: $0)?.host } ?? "an unknown website"
      switch request.hostStatus ?? .unrestricted {
      case .listed:
        facts.append(Fact("Sends to", "✓ \(host)"))
        return ApprovalPresentation(
          headline: "\(agent) wants to use your \(keyName) key", subtitle: subtitle,
          facts: facts, warning: nil, detailsExpanded: false, denyIsDefault: false,
          rememberableHost: nil)
      case .unrestricted:
        facts.append(Fact("Sends to", "\(host) (this key can go to any website)"))
        return ApprovalPresentation(
          headline: "\(agent) wants to use your \(keyName) key", subtitle: subtitle,
          facts: facts, warning: nil, detailsExpanded: false, denyIsDefault: false,
          rememberableHost: nil)
      case .unlisted(let allowed):
        facts.append(Fact("Sends to", host))
        return ApprovalPresentation(
          headline: "\(agent) wants to send your \(keyName) key somewhere new",
          subtitle: subtitle, facts: facts,
          warning: Warning(
            title: "\(host) isn't one of this key's usual websites",
            message:
              "This key normally only goes to \(allowed.joined(separator: ", ")). Only allow this if you know why."
          ),
          detailsExpanded: true, denyIsDefault: true, rememberableHost: host)
      }

    case .command, .environment:
      let headline: String
      if request.kind == .environment {
        let count = request.environmentVariables.count
        headline =
          "\(agent) wants to start \(commandSummary(request)) with \(count) key\(count == 1 ? "" : "s")"
        facts.append(Fact("Keys", request.environmentVariables.joined(separator: ", ")))
      } else {
        headline = "\(agent) wants to run a command with your \(keyName) key"
      }

      var warning: Warning?
      if let risk, risk.level != .normal {
        warning = Warning(
          title: risk.level == .high ? "Review this command" : "Check this command",
          message: risk.reasons.first ?? "This command needs a closer look.")
      }
      return ApprovalPresentation(
        headline: headline, subtitle: subtitle, facts: facts, warning: warning,
        detailsExpanded: warning != nil, denyIsDefault: risk?.level == .high,
        rememberableHost: nil)
    }
  }

  /// `npm run dev` from `/opt/homebrew/bin/npm` + `["run", "dev"]`, shortened for a headline.
  static func commandSummary(_ request: AgentRequest) -> String {
    let program = request.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
    let words = ([program ?? "a command"] + request.arguments).joined(separator: " ")
    return words.count > 40 ? String(words.prefix(39)) + "…" : words
  }
}
