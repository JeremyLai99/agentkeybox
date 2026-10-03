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
}

public struct CredentialMetadata: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var label: String
  public var service: String
  public var projectID: UUID?
  public var environment: String?
  public var kind: CredentialKind
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    label: String,
    service: String,
    projectID: UUID? = nil,
    environment: String? = nil,
    kind: CredentialKind = .apiKey,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.label = label
    self.service = service
    self.projectID = projectID
    self.environment = environment
    self.kind = kind
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum ApprovalScope: String, Codable, Sendable {
  case once
  case session
  case project
}

public struct AgentRequest: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
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
}

public struct AccessEvent: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var requestID: UUID
  public var agentDisplayName: String
  public var credentialLabel: String
  public var projectPath: String
  public var decision: ApprovalDecision
  public var timestamp: Date

  public init(
    id: UUID = UUID(),
    requestID: UUID,
    agentDisplayName: String,
    credentialLabel: String,
    projectPath: String,
    decision: ApprovalDecision,
    timestamp: Date = Date()
  ) {
    self.id = id
    self.requestID = requestID
    self.agentDisplayName = agentDisplayName
    self.credentialLabel = credentialLabel
    self.projectPath = projectPath
    self.decision = decision
    self.timestamp = timestamp
  }
}
