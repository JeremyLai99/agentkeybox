import Foundation

public struct Project: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var name: String
  public var rootPath: String

  public init(id: UUID = UUID(), name: String, rootPath: String) {
    self.id = id
    self.name = name
    self.rootPath = rootPath
  }
}

public enum CredentialKind: String, Codable, CaseIterable, Sendable {
  case apiKey
  case token
  case p8
  case pem
  case json
  case environmentVariable
  case creditCard
  case recoveryCodes
  case login

  /// These values must remain inside the dedicated submission/browser executors.
  public var requiresControlledUse: Bool {
    self == .creditCard || self == .recoveryCodes || self == .login
  }

  public var protectedTitle: String {
    switch self {
    case .login: return "Website login"
    case .creditCard: return "Credit card"
    default: return "Recovery codes"
    }
  }
}

public struct CredentialMetadata: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var label: String
  public var service: String
  public var projectID: UUID?
  public var environment: String?
  public var kind: CredentialKind
  /// Environment variable the credential is injected as, e.g. `STRIPE_SECRET_KEY`.
  public var environmentVariableName: String?
  /// Hosts `http_request` may send this credential to; `*.example.com` matches subdomains.
  /// Nil means unrestricted, which the approval prompt flags.
  public var allowedHosts: [String]?
  /// Non-secret values that belong with the key, by variable name, e.g. `ASC_ISSUER_ID` for an
  /// App Store Connect key or `SUPABASE_URL` for a Supabase key. They are shown on the key's
  /// card, listed to agents, and set next to the key when an approved command runs.
  public var settings: [String: String]?
  /// User-configured exact HTTPS endpoint for controlled field submission. No wildcard hosts.
  public var submissionURL: String?
  /// Native-user configured sign-in page. Login values themselves stay in Keychain.
  public var loginURL: String?
  /// Native-user selected login whose same-origin recovery form may receive these codes.
  public var linkedLoginID: UUID?
  /// Non-secret cached counts. Listing metadata must never read Keychain.
  public var recoveryCodeCounts: RecoveryCodeCounts?
  /// Write-ahead reservation revision; only authenticated native review may reconcile it.
  public var recoveryCodePendingRevision: UUID?
  /// Binds protected metadata to its Keychain payload; a partial edit must fail closed.
  public var payloadRevision: UUID?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    label: String,
    service: String,
    projectID: UUID? = nil,
    environment: String? = nil,
    kind: CredentialKind = .apiKey,
    environmentVariableName: String? = nil,
    allowedHosts: [String]? = nil,
    settings: [String: String]? = nil,
    submissionURL: String? = nil,
    loginURL: String? = nil,
    linkedLoginID: UUID? = nil,
    recoveryCodeCounts: RecoveryCodeCounts? = nil,
    payloadRevision: UUID? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.label = label
    self.service = service
    self.projectID = projectID
    self.environment = environment
    self.kind = kind
    self.environmentVariableName = environmentVariableName
    self.allowedHosts = allowedHosts
    self.settings = settings
    self.submissionURL = submissionURL
    self.loginURL = loginURL
    self.linkedLoginID = linkedLoginID
    self.recoveryCodeCounts = recoveryCodeCounts
    self.payloadRevision = payloadRevision
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  /// The variable name used when injecting into a process. Metadata saved before
  /// `environmentVariableName` existed falls back to the label when it is a valid name.
  public var injectionVariableName: String? {
    guard !kind.requiresControlledUse else { return nil }
    if let environmentVariableName, !environmentVariableName.isEmpty {
      return ApprovedCommandRunner.isAllowedInjectionTarget(environmentVariableName)
        ? environmentVariableName : nil
    }
    return ApprovedCommandRunner.isAllowedInjectionTarget(label) ? label : nil
  }

  /// File-style credentials are delivered as temporary files, not as environment text.
  public var isFileCredential: Bool {
    kind == .p8 || kind == .pem || kind == .json
  }
}

public enum ApprovalScope: String, Codable, Sendable {
  case once
  case session
  case project
}

public enum AgentRequestKind: String, Codable, Sendable {
  case command
  case httpRequest
  case environment
  case sensitiveSubmission
  case browserLogin
  case browserFollow
  case browserRecovery
}

public struct AgentRequest: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var kind: AgentRequestKind = .command
  public var httpMethod: String?
  public var url: String?
  public var headerNames: [String] = []
  public var bodyPreview: String?
  public var hostStatus: HTTPHostStatus?
  /// Snapshot bound to the approval so edits while prompting invalidate controlled use.
  public var credentialVersion: Date?
  /// For `.environment`: variable names that will be revealed to the requesting terminal.
  public var environmentVariables: [String] = []
  public var agentID: String
  public var agentDisplayName: String
  public var projectPath: String
  public var credentialIdentifier: String
  public var purpose: String?
  public var operation: String?
  public var executablePath: String?
  public var arguments: [String]
  public var environmentVariable: String?
  public var deliveryMode: SecretDeliveryMode
  public var requestedScope: ApprovalScope
  public var sessionID: String?
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    agentID: String,
    agentDisplayName: String,
    projectPath: String,
    credentialIdentifier: String,
    purpose: String? = nil,
    operation: String? = nil,
    executablePath: String? = nil,
    arguments: [String] = [],
    environmentVariable: String? = nil,
    deliveryMode: SecretDeliveryMode = .environment,
    requestedScope: ApprovalScope = .once,
    sessionID: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.agentID = agentID
    self.agentDisplayName = agentDisplayName
    self.projectPath = projectPath
    self.credentialIdentifier = credentialIdentifier
    self.purpose = purpose
    self.operation = operation
    self.executablePath = executablePath
    self.arguments = arguments
    self.environmentVariable = environmentVariable
    self.deliveryMode = deliveryMode
    self.requestedScope = requestedScope
    self.sessionID = sessionID
    self.createdAt = createdAt
  }
}

public enum ApprovalDecision: String, Codable, Sendable {
  case allowOnce
  case allowSession
  case allowProject
  case deny
  /// Nobody answered the prompt in time. Recorded in the history only; never sent to an agent.
  case timedOut

  /// Whether the agent got to use the credential.
  public var isAllowed: Bool {
    switch self {
    case .allowOnce, .allowSession, .allowProject: return true
    case .deny, .timedOut: return false
    }
  }

  /// How the access history shows this decision.
  public var historyText: String {
    switch self {
    case .allowOnce, .allowProject: return L("Allowed")
    case .allowSession: return L("Allowed (session)")
    case .deny: return L("Denied")
    case .timedOut: return L("Timed out")
    }
  }
}

public struct AccessEvent: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var requestID: UUID
  public var agentDisplayName: String
  public var credentialLabel: String
  public var projectPath: String
  public var decision: ApprovalDecision
  public var timestamp: Date
  /// The credentials this decision covered (several for `akb run`). Optional so access logs
  /// written before this field existed still decode.
  public var credentialIDs: [UUID]?

  public init(
    id: UUID = UUID(),
    requestID: UUID,
    agentDisplayName: String,
    credentialLabel: String,
    projectPath: String,
    decision: ApprovalDecision,
    timestamp: Date = Date(),
    credentialIDs: [UUID]? = nil
  ) {
    self.id = id
    self.requestID = requestID
    self.agentDisplayName = agentDisplayName
    self.credentialLabel = credentialLabel
    self.projectPath = projectPath
    self.decision = decision
    self.timestamp = timestamp
    self.credentialIDs = credentialIDs
  }
}
