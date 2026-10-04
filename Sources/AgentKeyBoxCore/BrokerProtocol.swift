import Foundation

public enum BrokerEndpoint {
  /// Unix-domain socket inside the owner-only (0700) AgentKeyBox support directory.
  /// Unlike a fixed TCP port, other users cannot connect to or squat on this path.
  public static var defaultSocketURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agentkeybox")
    return
      base
      .appendingPathComponent("AgentKeyBox", isDirectory: true)
      .appendingPathComponent("broker.sock")
  }

  /// `sockaddr_un.sun_path` holds 104 bytes including the terminating NUL.
  public static let maxSocketPathBytes = 103

  /// Approval wait (120s, including Touch ID) + command timeout (60s) + kill escalation + margin.
  public static let defaultClientTimeout: TimeInterval = 200

  /// How long the user has to find and paste a requested credential.
  public static let credentialRequestTimeout: TimeInterval = 600
  public static let credentialRequestClientTimeout: TimeInterval = credentialRequestTimeout + 30
}

public enum BrokerAction: String, Codable, Sendable {
  case listCredentials
  case executeWithSecret
  /// AgentKeyBox performs one HTTPS request with the credential placed in a header.
  case httpRequest
  /// `akb run`: after approval, the project's secrets are returned to the requesting terminal
  /// process so it can exec the user's command with them in its environment.
  case revealEnvironment
  /// An agent needs a credential that is not stored yet; the user enters it in AgentKeyBox.
  case requestCredential
}

public struct CredentialSummary: Codable, Hashable, Sendable {
  public var id: UUID
  public var label: String
  public var service: String
  public var environment: String?
  public var kind: CredentialKind
  public var environmentVariableName: String?
  public var allowedHosts: [String]?

  public init(metadata: CredentialMetadata) {
    self.id = metadata.id
    self.label = metadata.label
    self.service = metadata.service
    self.environment = metadata.environment
    self.kind = metadata.kind
    self.environmentVariableName = metadata.injectionVariableName
    self.allowedHosts = metadata.allowedHosts
  }
}

public struct BrokerRequest: Codable, Sendable {
  public var requestID: UUID
  public var issuedAt: Date
  public var authToken: String?
  public var action: BrokerAction
  public var agentID: String
  public var agentDisplayName: String
  public var projectPath: String
  public var credentialIdentifier: String?
  public var purpose: String?
  public var executablePath: String?
  public var arguments: [String]?
  public var environmentVariable: String?
  public var deliveryMode: SecretDeliveryMode
  public var requestedScope: ApprovalScope
  public var sessionID: String?
  public var httpMethod: String?
  public var url: String?
  public var headers: [String: String]?
  public var body: String?
  /// `revealEnvironment`: restrict to these variable names; nil means every project secret.
  public var requestedEnvironmentVariables: [String]?
  /// `requestCredential`: provider hint such as "Stripe".
  public var credentialService: String?

  public init(
    requestID: UUID = UUID(),
    issuedAt: Date = Date(),
    authToken: String? = nil,
    action: BrokerAction,
    agentID: String,
    agentDisplayName: String,
    projectPath: String,
    credentialIdentifier: String? = nil,
    purpose: String? = nil,
    executablePath: String? = nil,
    arguments: [String]? = nil,
    environmentVariable: String? = nil,
    deliveryMode: SecretDeliveryMode = .environment,
    requestedScope: ApprovalScope = .once,
    sessionID: String? = nil,
    httpMethod: String? = nil,
    url: String? = nil,
    headers: [String: String]? = nil,
    body: String? = nil,
    requestedEnvironmentVariables: [String]? = nil,
    credentialService: String? = nil
  ) {
    self.requestID = requestID
    self.issuedAt = issuedAt
    self.authToken = authToken
    self.action = action
    self.agentID = agentID
    self.agentDisplayName = agentDisplayName
    self.projectPath = projectPath
    self.credentialIdentifier = credentialIdentifier
    self.purpose = purpose
    self.executablePath = executablePath
    self.arguments = arguments
    self.environmentVariable = environmentVariable
    self.deliveryMode = deliveryMode
    self.requestedScope = requestedScope
    self.sessionID = sessionID
    self.httpMethod = httpMethod
    self.url = url
    self.headers = headers
    self.body = body
    self.requestedEnvironmentVariables = requestedEnvironmentVariables
    self.credentialService = credentialService
  }
}

public struct BrokerResponse: Codable, Sendable {
  public var ok: Bool
  public var error: String?
  public var credentials: [CredentialSummary]?
  public var decision: ApprovalDecision?
  public var execution: CommandExecutionResult?
  public var http: HTTPExecutionResult?
  /// `revealEnvironment` only: variable name → secret value, for the approved terminal process.
  public var environment: [String: String]?
  /// Secrets the user approved but that could not be injected as text (file credentials).
  public var skippedEnvironmentVariables: [String]?

  public init(
    ok: Bool,
    error: String? = nil,
    credentials: [CredentialSummary]? = nil,
    decision: ApprovalDecision? = nil,
    execution: CommandExecutionResult? = nil,
    http: HTTPExecutionResult? = nil,
    environment: [String: String]? = nil,
    skippedEnvironmentVariables: [String]? = nil
  ) {
    self.ok = ok
    self.error = error
    self.credentials = credentials
    self.decision = decision
    self.execution = execution
    self.http = http
    self.environment = environment
    self.skippedEnvironmentVariables = skippedEnvironmentVariables
  }
}

public enum BrokerError: Error, LocalizedError, Equatable {
  case appNotRunning
  case invalidResponse
  case requestFailed(String)
  case requestTimedOut
  case brokerAuthenticationUnavailable
  case unsupportedPlatform
  case socketPathTooLong

  public var errorDescription: String? {
    switch self {
    case .appNotRunning:
      return "AgentKeyBox is not running. Open the AgentKeyBox app and try again."
    case .invalidResponse:
      return "AgentKeyBox returned an invalid response."
    case .requestFailed(let message):
      return message
    case .requestTimedOut:
      return "AgentKeyBox approval timed out."
    case .brokerAuthenticationUnavailable:
      return "AgentKeyBox local authentication is unavailable. Open AgentKeyBox once and try again."
    case .unsupportedPlatform:
      return "AgentKeyBox broker is currently supported on macOS only."
    case .socketPathTooLong:
      return "AgentKeyBox broker socket path exceeds the Unix-domain socket length limit."
    }
  }
}
