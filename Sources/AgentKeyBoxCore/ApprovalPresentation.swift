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
  /// Checkbox text for "don't ask again this session", or nil when it is not offered. Never
  /// offered next to a warning: flagged requests are decided one at a time.
  public var sessionApprovalLabel: String?

  public static func make(
    for request: AgentRequest,
    credential: CredentialMetadata?,
    projectName: String?,
    risk: CommandRiskAssessment?
  ) -> ApprovalPresentation {
    var presentation = base(
      for: request, credential: credential, projectName: projectName, risk: risk)
    if presentation.warning == nil, ApprovalEngine.canGrantSession(for: request) {
      let agent = agentText(request.agentDisplayName, limit: 40)
      if request.kind == .httpRequest,
        let host = request.url.flatMap({ URLComponents(string: $0)?.host })
      {
        presentation.sessionApprovalLabel =
          L("Don't ask again for %@ during this %@ session", host, agent)
      } else {
        presentation.sessionApprovalLabel =
          L("Don't ask again for this command during this %@ session", agent)
      }
    }
    return presentation
  }

  private static func base(
    for request: AgentRequest,
    credential: CredentialMetadata?,
    projectName: String?,
    risk: CommandRiskAssessment?
  ) -> ApprovalPresentation {
    let agent = agentText(request.agentDisplayName, limit: 40)
    let keyName = credential.map { $0.service.isEmpty ? $0.label : $0.service }
    let useHeadline =
      keyName.map { L("%@ wants to use your %@ key", agent, $0) }
      ?? L("%@ wants to use a key", agent)
    let subtitle = projectName.map { L("in %@", $0) }
    var facts: [Fact] = []
    // The agent writes its own reason; label it as such, quote it, and keep it to one short
    // line so it cannot imitate the prompt's own text or push a warning out of view.
    if let purpose = request.purpose.map({ agentText($0, limit: 160) }), !purpose.isEmpty {
      facts.append(Fact(L("Agent's reason"), L("“%@”", purpose)))
    }

    switch request.kind {
    case .httpRequest:
      let host = request.url.flatMap { URLComponents(string: $0)?.host } ?? L("an unknown website")
      switch request.hostStatus ?? .unrestricted {
      case .listed:
        facts.append(Fact(L("Sends to"), "✓ \(host)"))
        return ApprovalPresentation(
          headline: useHeadline, subtitle: subtitle,
          facts: facts, warning: nil, detailsExpanded: false, denyIsDefault: false,
          rememberableHost: nil, sessionApprovalLabel: nil)
      case .unrestricted:
        facts.append(Fact(L("Sends to"), L("%@ (this key can go to any website)", host)))
        return ApprovalPresentation(
          headline: useHeadline, subtitle: subtitle,
          facts: facts, warning: nil, detailsExpanded: false, denyIsDefault: false,
          rememberableHost: nil, sessionApprovalLabel: nil)
      case .unlisted(let allowed):
        facts.append(Fact(L("Sends to"), host))
        return ApprovalPresentation(
          headline: keyName.map { L("%@ wants to send your %@ key somewhere new", agent, $0) }
            ?? L("%@ wants to send a key somewhere new", agent),
          subtitle: subtitle, facts: facts,
          warning: Warning(
            title: L("%@ isn't one of this key's usual websites", host),
            message: L(
              "This key normally only goes to %@. Only allow this if you know why.",
              allowed.joined(separator: ", "))
          ),
          detailsExpanded: true, denyIsDefault: true, rememberableHost: host,
          sessionApprovalLabel: nil)
      }

    case .command, .environment:
      let headline: String
      if request.kind == .environment {
        let count = request.environmentVariables.count
        headline =
          count == 1
          ? L("%@ wants to start %@ with 1 key", agent, commandSummary(request))
          : L("%@ wants to start %@ with %@ keys", agent, commandSummary(request), "\(count)")
        facts.append(Fact(L("Keys"), request.environmentVariables.joined(separator: ", ")))
      } else {
        headline =
          keyName.map { L("%@ wants to run a command with your %@ key", agent, $0) }
          ?? L("%@ wants to run a command with a key", agent)
      }

      var warning: Warning?
      if let risk, risk.level != .normal {
        warning = Warning(
          title: risk.level == .high ? L("Review this command") : L("Check this command"),
          message: risk.reasons.first ?? L("This command needs a closer look."))
      }
      return ApprovalPresentation(
        headline: headline, subtitle: subtitle, facts: facts, warning: warning,
        detailsExpanded: warning != nil, denyIsDefault: risk?.level == .high,
        rememberableHost: nil, sessionApprovalLabel: nil)
    }
  }

  /// Text supplied by the agent (its name, its reason) on one line: control characters and line
  /// breaks become spaces, runs of spaces collapse, and long text is cut with "…".
  public static func agentText(_ text: String, limit: Int) -> String {
    let flattened = String(
      text.unicodeScalars.map {
        CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
          ? " " : Character($0)
      })
    let collapsed = flattened.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
  }

  /// `npm run dev` from `/opt/homebrew/bin/npm` + `["run", "dev"]`, shortened for a headline.
  static func commandSummary(_ request: AgentRequest) -> String {
    let program = request.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
    let words = ([program ?? L("a command")] + request.arguments).joined(separator: " ")
    return words.count > 40 ? String(words.prefix(39)) + "…" : words
  }
}
