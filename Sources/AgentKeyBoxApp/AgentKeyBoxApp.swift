#if os(macOS)
  import SwiftUI
  import AppKit
  import AgentKeyBoxCore

  @main
  struct AgentKeyBoxApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
      WindowGroup {
        ContentView()
          .environmentObject(model)
          .frame(minWidth: 860, minHeight: 560)
      }
    }
  }

  /// An agent asked for a credential that AgentKeyBox does not have yet.
  struct CredentialRequestPrompt: Identifiable {
    let id = UUID()
    var agentDisplayName: String
    var projectPath: String
    var environmentVariable: String
    var service: String
    var purpose: String?
    var preset: ProviderPreset?
    /// Nil when the project folder is not in AgentKeyBox yet; saving adds it.
    var existingProject: Project?
  }

  @MainActor
  final class AppModel: ObservableObject {
    @Published var projects: [Project]
    @Published var credentials: [CredentialMetadata]
    @Published var pendingRequest: AgentRequest?
    @Published var pendingCredentialRequest: CredentialRequestPrompt?
    @Published var statusMessage: String?
    @Published var brokerStatus: String = "Starting local broker…"
    @Published var claudeConnectionStatus: String = "Not checked"
    @Published var codexConnectionStatus: String = "Not checked"
    @Published var accessEvents: [AccessEvent] = []

    private let secretStore = KeychainSecretStore()
    private let approvalEngine = ApprovalEngine()
    private let metadataStore = MetadataStore()
    private let brokerTokenStore = BrokerTokenStore()
    private let authenticator = LocalAuthenticator()
    private var brokerServer: LocalBrokerServer?
    private var pendingBrokerContinuation: CheckedContinuation<BrokerResponse, Never>?
    private var pendingBrokerRequest: BrokerRequest?
    private var pendingApprovalTimeoutTask: Task<Void, Never>?
    private var decisionInProgress = false
    /// Claimed synchronously before the first suspension point so concurrent broker requests
    /// cannot both pass the "nothing pending" check while the main actor is re-entered.
    private var approvalSlotReserved = false

    init() {
      let snapshot = metadataStore.load()
      self.projects = snapshot.projects
      self.credentials = snapshot.credentials

      do {
        let authToken = try brokerTokenStore.loadOrCreate()
        let server = LocalBrokerServer(expectedAuthToken: authToken) { [weak self] request in
          guard let self else {
            return BrokerResponse(ok: false, error: "AgentKeyBox is unavailable.")
          }
          return await self.handleBrokerRequest(request)
        }
        self.brokerServer = server
        try server.start()
        self.brokerStatus = "Local broker ready on this Mac"
      } catch {
        self.brokerStatus = "Broker unavailable: \(error.localizedDescription)"
      }
    }

    deinit {
      pendingApprovalTimeoutTask?.cancel()
      brokerServer?.stop()
    }

    // MARK: - Projects and credentials

    @discardableResult
    func addProject(name: String, rootPath: String) -> Project? {
      let normalizedPath = normalize(rootPath)
      if let existing = projects.first(where: { normalize($0.rootPath) == normalizedPath }) {
        statusMessage = "That project is already in AgentKeyBox."
        return existing
      }
      let project = Project(name: name, rootPath: normalizedPath)
      projects.append(project)
      guard persistMetadata() else {
        projects.removeAll { $0.id == project.id }
        return nil
      }
      statusMessage = "Project added."
      return project
    }

    @discardableResult
    func addCredential(
      label: String,
      service: String,
      secret: Data,
      projectID: UUID?,
      environment: String? = nil,
      kind: CredentialKind = .apiKey,
      environmentVariableName: String? = nil,
      allowedHosts: [String]? = nil
    ) -> CredentialMetadata? {
      let metadata = CredentialMetadata(
        label: label,
        service: service,
        projectID: projectID,
        environment: environment,
        kind: kind,
        environmentVariableName: environmentVariableName,
        allowedHosts: allowedHosts
      )
      do {
        try secretStore.save(secret: secret, id: metadata.id)
        credentials.append(metadata)
        guard persistMetadata() else {
          credentials.removeAll { $0.id == metadata.id }
          try? secretStore.delete(id: metadata.id)
          return nil
        }
        statusMessage = "Saved securely in Keychain."
        return metadata
      } catch {
        statusMessage = "Could not save secret: \(error.localizedDescription)"
        return nil
      }
    }

    func deleteCredential(_ credential: CredentialMetadata) {
      guard let index = credentials.firstIndex(where: { $0.id == credential.id }) else { return }
      credentials.remove(at: index)
      guard persistMetadata() else {
        credentials.insert(credential, at: min(index, credentials.count))
        return
      }
      do {
        try secretStore.delete(id: credential.id)
        statusMessage = "Credential deleted."
      } catch {
        statusMessage =
          "Credential metadata was removed, but Keychain cleanup failed: \(error.localizedDescription)"
      }
    }

    func importEnv(at url: URL, projectID: UUID?) {
      do {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = EnvParser.parse(text)
        guard !parsed.isEmpty else {
          statusMessage = "No environment variables were found in that file."
          return
        }

        var staged: [CredentialMetadata] = []
        do {
          for (key, value) in parsed.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
            let preset = ProviderCatalog.preset(matchingService: nil, environmentKey: key)
            let metadata = CredentialMetadata(
              label: key,
              service: ProviderCatalog.inferService(fromEnvironmentKey: key),
              projectID: projectID,
              kind: .environmentVariable,
              environmentVariableName: key,
              allowedHosts: preset.flatMap { $0.allowedHosts.isEmpty ? nil : $0.allowedHosts }
            )
            try secretStore.save(secret: Data(value.utf8), id: metadata.id)
            staged.append(metadata)
          }
        } catch {
          for metadata in staged { try? secretStore.delete(id: metadata.id) }
          throw error
        }

        credentials.append(contentsOf: staged)
        guard persistMetadata() else {
          let stagedIDs = Set(staged.map(\.id))
          credentials.removeAll { stagedIDs.contains($0.id) }
          for metadata in staged { try? secretStore.delete(id: metadata.id) }
          return
        }
        statusMessage = "Imported \(staged.count) secret\(staged.count == 1 ? "" : "s") from .env."
      } catch {
        statusMessage = "Could not import .env: \(error.localizedDescription)"
      }
    }

    func importCredentialFile(at url: URL, projectID: UUID?) {
      do {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let kind: CredentialKind
        let service: String
        switch ext {
        case "p8":
          kind = .p8
          service = "Apple"
        case "pem":
          kind = .pem
          service = "Certificate"
        case "json":
          kind = .json
          service = "Service Account"
        default:
          statusMessage = "Supported credential files are .p8, .pem, and .json."
          return
        }

        addCredential(
          label: url.lastPathComponent,
          service: service,
          secret: data,
          projectID: projectID,
          kind: kind
        )
      } catch {
        statusMessage = "Could not import credential file: \(error.localizedDescription)"
      }
    }

    func simulateRequest(agentID: String = "claude-code", agentName: String = "Claude Code") {
      guard let credential = credentials.first else {
        statusMessage = "Add a credential first."
        return
      }
      guard !approvalSlotReserved, pendingRequest == nil, pendingCredentialRequest == nil else {
        statusMessage = "Finish the pending approval first."
        return
      }
      let project = projects.first
      pendingBrokerRequest = nil
      pendingRequest = AgentRequest(
        agentID: agentID,
        agentDisplayName: agentName,
        projectPath: project?.rootPath ?? FileManager.default.homeDirectoryForCurrentUser.path,
        credentialIdentifier: credential.id.uuidString,
        purpose: "Use \(credential.service) for the current coding task",
        operation: "/usr/bin/true",
        executablePath: "/usr/bin/true",
        arguments: []
      )
      NSApp.activate(ignoringOtherApps: true)
    }

    var keychainStatus: String {
      secretStore.usesDataProtectionKeychain
        ? "Every approval requires Touch ID or your login password. Secrets are protected by Touch ID in the data protection keychain."
        : "Every approval requires Touch ID or your login password. This unsigned development build uses the legacy keychain, so macOS may also ask for your login password after each rebuild."
    }

    func credentialSummary(for request: AgentRequest) -> CredentialMetadata? {
      guard let id = UUID(uuidString: request.credentialIdentifier) else { return nil }
      return credentials.first { $0.id == id }
    }

    // MARK: - Approval decisions

    func decide(_ decision: ApprovalDecision) {
      guard !decisionInProgress, let request = pendingRequest else { return }
      let credential = credentialSummary(for: request)
      if request.kind != .environment, credential == nil {
        finishPrompt(
          BrokerResponse(ok: false, error: "Credential was not found."),
          message: "Credential was not found."
        )
        return
      }

      decisionInProgress = true
      let brokerRequestAtDecision = pendingBrokerRequest
      let requestID = request.id
      let historyLabel =
        request.kind == .environment
        ? "\(request.environmentVariables.count) secret(s) for akb run"
        : (credential?.label ?? "credential")

      Task {
        // Every approval requires Touch ID or the login password. With the data protection
        // keychain the same authentication then unlocks the secrets, so there is one prompt.
        var grant: AuthenticationGrant?
        if decision != .deny {
          do {
            grant = try await authenticator.authenticate(
              reason: "Allow \(request.agentDisplayName) to use \(historyLabel)?"
            )
          } catch {
            guard self.pendingRequest?.id == requestID else { return }
            self.finishPrompt(
              BrokerResponse(ok: true, decision: .deny),
              message: "Local authentication cancelled or failed."
            )
            return
          }
        }

        // The approval may have timed out while Touch ID was on screen; do not record or run it.
        guard self.pendingRequest?.id == requestID else { return }
        // The user has decided, so the approval wait is over. From here the operation's own
        // timeout applies; otherwise a slow command would be reported as an approval timeout
        // after it already ran with the credential.
        self.pendingApprovalTimeoutTask?.cancel()
        self.pendingApprovalTimeoutTask = nil

        await approvalEngine.record(
          decision: decision, request: request, credentialLabel: historyLabel)
        self.accessEvents = Array((await approvalEngine.history()).prefix(20))

        if decision == .deny {
          guard self.pendingRequest?.id == requestID else { return }
          self.finishPrompt(BrokerResponse(ok: true, decision: .deny), message: "Access denied.")
          return
        }

        guard let brokerRequest = brokerRequestAtDecision else {
          guard self.pendingRequest?.id == requestID else { return }
          self.finishPrompt(
            BrokerResponse(ok: true, decision: decision),
            message: "Access approved: \(decision.rawValue)."
          )
          return
        }

        let response: BrokerResponse
        switch brokerRequest.action {
        case .executeWithSecret:
          response = await executeApprovedCommand(
            brokerRequest, credentialID: credential!.id, decision: decision, grant: grant)
        case .httpRequest:
          response = await executeApprovedHTTPRequest(
            brokerRequest, credential: credential!, decision: decision, grant: grant)
        case .revealEnvironment:
          response = await revealApprovedEnvironment(
            request.environmentVariables, projectPath: request.projectPath, decision: decision,
            grant: grant)
        case .listCredentials, .requestCredential:
          response = BrokerResponse(ok: false, error: "Unexpected approval type.")
        }

        guard self.pendingRequest?.id == requestID else { return }
        self.finishPrompt(
          response,
          message: response.ok
            ? "Approved request completed." : (response.error ?? "Approved request failed.")
        )
      }
    }

    // MARK: - Credential requests

    /// Saves the credential the user entered for an agent's `request_credential` call. The agent
    /// only receives its metadata, never the value.
    func submitCredentialRequest(secret: String) {
      guard let prompt = pendingCredentialRequest, !secret.isEmpty else { return }

      var project = prompt.existingProject
      if project == nil {
        project = addProject(
          name: URL(fileURLWithPath: prompt.projectPath).lastPathComponent,
          rootPath: prompt.projectPath)
      }
      guard let project else {
        statusMessage = "Could not add the project folder."
        return
      }

      let hosts = prompt.preset?.allowedHosts ?? []
      guard
        let metadata = addCredential(
          label: prompt.environmentVariable,
          service: prompt.service,
          secret: Data(secret.utf8),
          projectID: project.id,
          kind: prompt.preset?.defaultKind == .token ? .token : .apiKey,
          environmentVariableName: prompt.environmentVariable,
          allowedHosts: hosts.isEmpty ? nil : hosts
        )
      else { return }

      finishPrompt(
        BrokerResponse(ok: true, credentials: [CredentialSummary(metadata: metadata)]),
        message: "Saved \(prompt.environmentVariable) for \(project.name)."
      )
    }

    func cancelCredentialRequest() {
      guard pendingCredentialRequest != nil else { return }
      finishPrompt(
        BrokerResponse(ok: false, error: "The user declined to provide the credential."),
        message: "Credential request declined."
      )
    }

    // MARK: - Agent integrations

    func refreshAgentStatuses() {
      Task {
        let claude = await ClaudeCodeAdapter().integrationStatus()
        let codex = await CodexAdapter().integrationStatus()
        self.claudeConnectionStatus = self.displayStatus(claude)
        self.codexConnectionStatus = self.displayStatus(codex)
      }
    }

    func connectAll() {
      connectClaudeCode()
      connectCodex()
    }

    func connectClaudeCode() {
      connect(adapter: ClaudeCodeAdapter()) { self.claudeConnectionStatus = $0 }
    }

    func connectCodex() {
      connect(adapter: CodexAdapter()) { self.codexConnectionStatus = $0 }
    }

    private func connect<A: AgentAdapter>(adapter: A, update: @escaping @MainActor (String) -> Void)
    {
      guard let helper = MCPExecutableLocator.locate() else {
        update("MCP helper not found")
        statusMessage = AgentIntegrationError.helperNotFound.localizedDescription
        return
      }
      update("Connecting…")
      Task {
        do {
          try await adapter.installIntegration(mcpExecutablePath: helper)
          update("Connected")
          self.statusMessage =
            "Connected AgentKeyBox to \(adapter.displayName). Start a new agent session to load the MCP tools."
        } catch {
          update("Failed")
          self.statusMessage = error.localizedDescription
        }
      }
    }

    // MARK: - Broker

    private func handleBrokerRequest(_ brokerRequest: BrokerRequest) async -> BrokerResponse {
      if brokerRequest.action == .listCredentials {
        let visible = credentials.filter { credentialIsVisible($0, for: brokerRequest.projectPath) }
        return BrokerResponse(ok: true, credentials: visible.map(CredentialSummary.init(metadata:)))
      }

      guard !approvalSlotReserved, pendingRequest == nil, pendingCredentialRequest == nil else {
        return BrokerResponse(ok: false, error: "Another AgentKeyBox approval is already pending.")
      }
      approvalSlotReserved = true
      defer { approvalSlotReserved = false }

      switch brokerRequest.action {
      case .listCredentials:
        return BrokerResponse(ok: false, error: "Unexpected request.")
      case .executeWithSecret:
        return await handleExecuteRequest(brokerRequest)
      case .httpRequest:
        return await handleHTTPRequest(brokerRequest)
      case .revealEnvironment:
        return await handleRevealEnvironment(brokerRequest)
      case .requestCredential:
        return await handleCredentialRequest(brokerRequest)
      }
    }

    private func visibleCredential(for brokerRequest: BrokerRequest) -> CredentialMetadata? {
      guard let identifier = brokerRequest.credentialIdentifier,
        let credentialID = UUID(uuidString: identifier),
        let credential = credentials.first(where: { $0.id == credentialID }),
        credentialIsVisible(credential, for: brokerRequest.projectPath)
      else { return nil }
      return credential
    }

    private func handleExecuteRequest(_ brokerRequest: BrokerRequest) async -> BrokerResponse {
      guard let credential = visibleCredential(for: brokerRequest) else {
        return BrokerResponse(ok: false, error: "Credential is not available to this project.")
      }
      guard let executablePath = brokerRequest.executablePath,
        executablePath.hasPrefix("/"),
        let environmentVariable = brokerRequest.environmentVariable,
        ApprovedCommandRunner.isValidEnvironmentVariable(environmentVariable)
      else {
        return BrokerResponse(ok: false, error: "Invalid execution request.")
      }

      let operation = ([executablePath] + (brokerRequest.arguments ?? [])).joined(separator: " ")
      let request = AgentRequest(
        agentID: brokerRequest.agentID,
        agentDisplayName: brokerRequest.agentDisplayName,
        projectPath: normalize(brokerRequest.projectPath),
        credentialIdentifier: credential.id.uuidString,
        purpose: brokerRequest.purpose,
        operation: operation,
        executablePath: executablePath,
        arguments: brokerRequest.arguments ?? [],
        environmentVariable: environmentVariable,
        deliveryMode: brokerRequest.deliveryMode,
        requestedScope: brokerRequest.requestedScope,
        sessionID: brokerRequest.sessionID
      )

      if let preauthorized = await approvalEngine.preauthorizedDecision(for: request),
        preauthorized != .deny
      {
        // No grant: the data protection keychain shows its own user-presence prompt.
        return await executeApprovedCommand(
          brokerRequest, credentialID: credential.id, decision: preauthorized, grant: nil)
      }
      return await presentForApproval(request, brokerRequest: brokerRequest)
    }

    private func handleHTTPRequest(_ brokerRequest: BrokerRequest) async -> BrokerResponse {
      guard let credential = visibleCredential(for: brokerRequest) else {
        return BrokerResponse(ok: false, error: "Credential is not available to this project.")
      }
      // Rejected requests (wrong host, http://, misplaced placeholder) never reach the user.
      let validated: ValidatedHTTPRequest
      do {
        validated = try HTTPRequestPolicy.validate(
          method: brokerRequest.httpMethod ?? "GET",
          url: brokerRequest.url ?? "",
          headers: brokerRequest.headers ?? [:],
          body: brokerRequest.body,
          allowedHosts: credential.allowedHosts)
      } catch {
        return BrokerResponse(ok: false, error: error.localizedDescription)
      }

      var request = AgentRequest(
        agentID: brokerRequest.agentID,
        agentDisplayName: brokerRequest.agentDisplayName,
        projectPath: normalize(brokerRequest.projectPath),
        credentialIdentifier: credential.id.uuidString,
        purpose: brokerRequest.purpose,
        operation: "\(validated.method) \(validated.url.absoluteString)"
      )
      request.kind = .httpRequest
      request.httpMethod = validated.method
      request.url = validated.url.absoluteString
      request.headerNames = validated.headers.keys.sorted()
      request.bodyPreview = validated.body.map { String($0.prefix(400)) }
      request.hostAllowed = validated.hostRestricted
      return await presentForApproval(request, brokerRequest: brokerRequest)
    }

    private func handleRevealEnvironment(_ brokerRequest: BrokerRequest) async -> BrokerResponse {
      let selected = environmentCredentials(
        projectPath: brokerRequest.projectPath,
        only: brokerRequest.requestedEnvironmentVariables)
      guard !selected.isEmpty else {
        return BrokerResponse(
          ok: false,
          error:
            "No AgentKeyBox secrets with an environment variable name are available to this folder.")
      }
      guard let executablePath = brokerRequest.executablePath else {
        return BrokerResponse(ok: false, error: "Invalid run request.")
      }

      var request = AgentRequest(
        agentID: brokerRequest.agentID,
        agentDisplayName: brokerRequest.agentDisplayName,
        projectPath: normalize(brokerRequest.projectPath),
        credentialIdentifier: "",
        purpose: brokerRequest.purpose,
        operation: ([executablePath] + (brokerRequest.arguments ?? [])).joined(separator: " "),
        executablePath: executablePath,
        arguments: brokerRequest.arguments ?? []
      )
      request.kind = .environment
      request.environmentVariables = selected.keys.sorted()
      return await presentForApproval(request, brokerRequest: brokerRequest)
    }

    private func handleCredentialRequest(_ brokerRequest: BrokerRequest) async -> BrokerResponse {
      guard let variable = brokerRequest.environmentVariable,
        ApprovedCommandRunner.isValidEnvironmentVariable(variable)
      else {
        return BrokerResponse(ok: false, error: "env_var must be a valid environment variable name.")
      }
      let projectPath = normalize(brokerRequest.projectPath)

      // Avoid duplicates: hand back the credential the agent may have missed.
      if let existing = credentials.first(where: {
        $0.injectionVariableName == variable && credentialIsVisible($0, for: projectPath)
      }) {
        return BrokerResponse(ok: true, credentials: [CredentialSummary(metadata: existing)])
      }

      let preset = ProviderCatalog.preset(
        matchingService: brokerRequest.credentialService, environmentKey: variable)
      let service =
        preset?.displayName ?? brokerRequest.credentialService
        ?? ProviderCatalog.inferService(fromEnvironmentKey: variable)
      let existingProject =
        projects
        .filter {
          ProjectScopeResolver.contains(projectRoot: $0.rootPath, requestPath: projectPath)
        }
        .max { normalize($0.rootPath).count < normalize($1.rootPath).count }

      let prompt = CredentialRequestPrompt(
        agentDisplayName: brokerRequest.agentDisplayName,
        projectPath: projectPath,
        environmentVariable: variable,
        service: service,
        purpose: brokerRequest.purpose,
        preset: preset,
        existingProject: existingProject
      )
      return await waitForUser(timeout: BrokerEndpoint.credentialRequestTimeout) {
        self.pendingBrokerRequest = brokerRequest
        self.pendingCredentialRequest = prompt
      }
    }

    private func presentForApproval(_ request: AgentRequest, brokerRequest: BrokerRequest) async
      -> BrokerResponse
    {
      await waitForUser(timeout: 120) {
        self.pendingBrokerRequest = brokerRequest
        self.pendingRequest = request
      }
    }

    /// Shows a prompt and suspends until the user answers or the timeout fires.
    private func waitForUser(timeout: TimeInterval, present: () -> Void) async -> BrokerResponse {
      present()
      NSApp.activate(ignoringOtherApps: true)
      return await withCheckedContinuation { continuation in
        pendingBrokerContinuation = continuation
        pendingApprovalTimeoutTask?.cancel()
        let promptID = currentPromptID
        pendingApprovalTimeoutTask = Task { [weak self] in
          try? await Task.sleep(for: .seconds(timeout))
          guard !Task.isCancelled, let self, self.currentPromptID == promptID else { return }
          self.finishPrompt(
            BrokerResponse(ok: false, error: "Approval timed out."),
            message: "Approval timed out."
          )
        }
      }
    }

    private var currentPromptID: UUID? {
      pendingRequest?.id ?? pendingCredentialRequest?.id
    }

    // MARK: - Approved operations

    private func readSecret(_ credentialID: UUID, grant: AuthenticationGrant?) async throws -> Data?
    {
      // Off the main actor: without a grant the keychain may show a prompt and block.
      let secretStore = self.secretStore
      return try await Task.detached(priority: .userInitiated) {
        try secretStore.read(id: credentialID, grant: grant)
      }.value
    }

    private func executeApprovedCommand(
      _ brokerRequest: BrokerRequest,
      credentialID: UUID,
      decision: ApprovalDecision,
      grant: AuthenticationGrant?
    ) async -> BrokerResponse {
      guard let executablePath = brokerRequest.executablePath,
        let environmentVariable = brokerRequest.environmentVariable
      else {
        return BrokerResponse(ok: false, error: "Invalid approved execution request.")
      }

      let secret: Data
      do {
        guard let stored = try await readSecret(credentialID, grant: grant) else {
          return BrokerResponse(ok: false, error: "Credential value is missing from Keychain.")
        }
        secret = stored
      } catch {
        return BrokerResponse(ok: false, error: "Could not read credential from Keychain.")
      }

      let workingDirectory = normalize(brokerRequest.projectPath)
      let arguments = brokerRequest.arguments ?? []

      do {
        let execution = try await Task.detached(priority: .userInitiated) {
          try ApprovedCommandRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environmentVariable: environmentVariable,
            secretData: secret,
            deliveryMode: brokerRequest.deliveryMode
          )
        }.value
        return BrokerResponse(ok: true, decision: decision, execution: execution)
      } catch {
        return BrokerResponse(ok: false, error: error.localizedDescription)
      }
    }

    private func executeApprovedHTTPRequest(
      _ brokerRequest: BrokerRequest,
      credential: CredentialMetadata,
      decision: ApprovalDecision,
      grant: AuthenticationGrant?
    ) async -> BrokerResponse {
      do {
        // Re-validate against the current allowlist in case it changed while the prompt was open.
        let validated = try HTTPRequestPolicy.validate(
          method: brokerRequest.httpMethod ?? "GET",
          url: brokerRequest.url ?? "",
          headers: brokerRequest.headers ?? [:],
          body: brokerRequest.body,
          allowedHosts: credential.allowedHosts)
        guard let secret = try await readSecret(credential.id, grant: grant) else {
          return BrokerResponse(ok: false, error: "Credential value is missing from Keychain.")
        }
        let result = try await HTTPRequestExecutor.execute(validated, secretData: secret)
        return BrokerResponse(ok: true, decision: decision, http: result)
      } catch {
        return BrokerResponse(ok: false, error: error.localizedDescription)
      }
    }

    private func revealApprovedEnvironment(
      _ variables: [String],
      projectPath: String,
      decision: ApprovalDecision,
      grant: AuthenticationGrant?
    ) async -> BrokerResponse {
      let selected = environmentCredentials(projectPath: projectPath, only: variables)
      var environment: [String: String] = [:]
      var skipped: [String] = []
      for name in variables {
        guard let credential = selected[name] else {
          skipped.append(name)
          continue
        }
        do {
          guard let data = try await readSecret(credential.id, grant: grant),
            let value = String(data: data, encoding: .utf8)
          else {
            skipped.append(name)
            continue
          }
          environment[name] = value
        } catch {
          return BrokerResponse(ok: false, error: "Could not read \(name) from Keychain.")
        }
      }
      return BrokerResponse(
        ok: true, decision: decision, environment: environment,
        skippedEnvironmentVariables: skipped.isEmpty ? nil : skipped)
    }

    /// Text credentials visible to `projectPath`, keyed by variable name. When two share a name,
    /// a project-bound credential beats a global one, then the most recently updated wins.
    private func environmentCredentials(projectPath: String, only: [String]?) -> [String:
      CredentialMetadata]
    {
      var result: [String: CredentialMetadata] = [:]
      for credential in credentials
      where !credential.isFileCredential && credentialIsVisible(credential, for: projectPath) {
        guard let name = credential.injectionVariableName else { continue }
        if let only, !only.contains(name) { continue }
        if let current = result[name] {
          let currentRank = (current.projectID != nil ? 1 : 0, current.updatedAt)
          let candidateRank = (credential.projectID != nil ? 1 : 0, credential.updatedAt)
          if candidateRank <= currentRank { continue }
        }
        result[name] = credential
      }
      return result
    }

    private func credentialIsVisible(_ metadata: CredentialMetadata, for projectPath: String)
      -> Bool
    {
      ProjectScopeResolver.isVisible(metadata, projects: projects, requestPath: projectPath)
    }

    private func finishPrompt(_ response: BrokerResponse, message: String) {
      // A timed-out or otherwise finished request must not leave its Touch ID / password prompt
      // on screen; completing that stale prompt would do nothing.
      authenticator.cancelPendingAuthentication()
      decisionInProgress = false
      pendingApprovalTimeoutTask?.cancel()
      pendingApprovalTimeoutTask = nil
      statusMessage = message
      let continuation = pendingBrokerContinuation
      pendingBrokerContinuation = nil
      continuation?.resume(returning: response)
      pendingRequest = nil
      pendingCredentialRequest = nil
      pendingBrokerRequest = nil
    }

    @discardableResult
    private func persistMetadata() -> Bool {
      do {
        try metadataStore.save(MetadataSnapshot(projects: projects, credentials: credentials))
        return true
      } catch {
        statusMessage = "Metadata could not be persisted: \(error.localizedDescription)"
        return false
      }
    }

    private func normalize(_ path: String) -> String {
      ProjectScopeResolver.normalize(path)
    }

    private func displayStatus(_ status: AgentIntegrationStatus) -> String {
      switch status {
      case .notInstalled: return "Not installed"
      case .notConfigured: return "Not connected"
      case .configured: return "Connected"
      case .error: return "Unknown"
      }
    }

    func riskAssessment(for request: AgentRequest) -> CommandRiskAssessment? {
      guard request.kind != .httpRequest, let executablePath = request.executablePath else {
        return nil
      }
      return CommandRiskAnalyzer.assess(
        executablePath: executablePath, arguments: request.arguments)
    }
  }

  struct ContentView: View {
    private enum ImportKind {
      case env
      case credentialFile
    }

    private struct PendingImport {
      let url: URL
      let kind: ImportKind
    }

    @EnvironmentObject private var model: AppModel
    @State private var showingAddCredential = false
    @State private var pendingImport: PendingImport?

    var body: some View {
      NavigationSplitView {
        List {
          Section("Projects") {
            ForEach(model.projects) { project in
              VStack(alignment: .leading, spacing: 2) {
                Label(project.name, systemImage: "folder")
                Text(project.rootPath)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
            Button("Add Project…") { chooseProjectFolder() }
          }

          Section("Credentials") {
            ForEach(model.credentials) { credential in
              VStack(alignment: .leading, spacing: 3) {
                Text(credential.label)
                HStack(spacing: 6) {
                  Text(credential.service)
                  if let environment = credential.environment {
                    Text("· \(environment)")
                  }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              .contextMenu {
                Button("Delete", role: .destructive) {
                  model.deleteCredential(credential)
                }
              }
            }
          }
        }
        .navigationTitle("AgentKeyBox")
      } detail: {
        VStack(spacing: 18) {
          Image(systemName: "key.horizontal.fill")
            .font(.system(size: 54))
          Text("Keys for your AI agents, under your control.")
            .font(.title2)
          Text(model.brokerStatus)
            .font(.caption)
            .foregroundStyle(.secondary)

          HStack(spacing: 12) {
            Button("Connect Claude Code") { model.connectClaudeCode() }
            Text(model.claudeConnectionStatus).font(.caption).foregroundStyle(.secondary)
            Button("Connect Codex") { model.connectCodex() }
            Text(model.codexConnectionStatus).font(.caption).foregroundStyle(.secondary)
            Button("Connect Both") { model.connectAll() }
          }

          HStack {
            Button("Add Credential") { showingAddCredential = true }
              .buttonStyle(.borderedProminent)
            Button("Import .env…") { chooseEnvFile() }
            Button("Import Key File…") { chooseCredentialFile() }
          }

          Text(model.keychainStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)

          HStack {
            Button("Simulate Claude Request") { model.simulateRequest() }
              .disabled(model.credentials.isEmpty)
            Button("Simulate Codex Request") {
              model.simulateRequest(agentID: "codex", agentName: "Codex")
            }
            .disabled(model.credentials.isEmpty)
          }

          if let message = model.statusMessage {
            Text(message)
              .font(.callout)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }

          if !model.accessEvents.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
              Text("Recent access").font(.headline)
              ForEach(model.accessEvents.prefix(5)) { event in
                HStack {
                  Text(event.agentDisplayName)
                  Text("·")
                  Text(event.credentialLabel)
                  Spacer()
                  Text(event.decision.rawValue)
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
              }
            }
            .frame(maxWidth: 520)
          }
          Spacer()
        }
        .padding(36)
      }
      .sheet(isPresented: $showingAddCredential) {
        AddCredentialView()
          .environmentObject(model)
      }
      .confirmationDialog(
        "Which project should these credentials belong to?",
        isPresented: Binding(
          get: { pendingImport != nil },
          set: { if !$0 { pendingImport = nil } }
        ),
        presenting: pendingImport
      ) { item in
        ForEach(model.projects) { project in
          Button(project.name) { performImport(item, projectID: project.id) }
        }
        Button("Global (visible to every project)") { performImport(item, projectID: nil) }
        Button("Cancel", role: .cancel) {}
      } message: { item in
        Text(item.url.lastPathComponent)
      }
      .sheet(item: $model.pendingRequest) { request in
        ApprovalView(request: request)
          .environmentObject(model)
      }
      .sheet(item: $model.pendingCredentialRequest) { prompt in
        CredentialRequestView(prompt: prompt)
          .environmentObject(model)
      }
      .task {
        model.refreshAgentStatuses()
      }
    }

    private func chooseProjectFolder() {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.prompt = "Add Project"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      model.addProject(name: url.lastPathComponent, rootPath: url.path)
    }

    private func chooseEnvFile() {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = false
      panel.canChooseFiles = true
      panel.allowsMultipleSelection = false
      panel.prompt = "Import"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      pendingImport = PendingImport(url: url, kind: .env)
    }

    private func chooseCredentialFile() {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = false
      panel.canChooseFiles = true
      panel.allowsMultipleSelection = false
      panel.allowedContentTypes = []
      panel.prompt = "Import"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      pendingImport = PendingImport(url: url, kind: .credentialFile)
    }

    private func performImport(_ item: PendingImport, projectID: UUID?) {
      switch item.kind {
      case .env:
        model.importEnv(at: item.url, projectID: projectID)
      case .credentialFile:
        model.importCredentialFile(at: item.url, projectID: projectID)
      }
    }
  }

  struct AddCredentialView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var service = ""
    @State private var environment = ""
    @State private var environmentVariableName = ""
    @State private var allowedHosts = ""
    @State private var secret = ""
    @State private var selectedProjectID: UUID?
    @State private var selectedKind: CredentialKind = .apiKey

    var body: some View {
      VStack(alignment: .leading, spacing: 14) {
        Text("Add Credential").font(.title2.bold())
        Menu("Use Provider Preset") {
          ForEach(ProviderCatalog.all) { preset in
            Button(preset.displayName) {
              service = preset.displayName
              selectedKind = preset.defaultKind
              if let key = preset.environmentKeys.first {
                if label.isEmpty { label = key }
                if environmentVariableName.isEmpty { environmentVariableName = key }
              }
              allowedHosts = preset.allowedHosts.joined(separator: ", ")
            }
          }
        }
        TextField("Label (e.g. Stripe Production)", text: $label)
        TextField("Service (e.g. Stripe)", text: $service)
        TextField("Environment variable (e.g. STRIPE_SECRET_KEY)", text: $environmentVariableName)
        TextField("Allowed hosts for http_request (e.g. api.stripe.com)", text: $allowedHosts)
        TextField("Environment (optional)", text: $environment)
        Picker("Project", selection: $selectedProjectID) {
          Text("Global").tag(UUID?.none)
          ForEach(model.projects) { project in
            Text(project.name).tag(Optional(project.id))
          }
        }
        Picker("Type", selection: $selectedKind) {
          ForEach(CredentialKind.allCases, id: \.self) { kind in
            Text(kind.rawValue).tag(kind)
          }
        }
        SecureField("Secret", text: $secret)
        HStack {
          Spacer()
          Button("Cancel") { dismiss() }
          Button("Save") {
            let hosts =
              allowedHosts
              .split(whereSeparator: { $0 == "," || $0.isWhitespace })
              .map(String.init)
            model.addCredential(
              label: label,
              service: service,
              secret: Data(secret.utf8),
              projectID: selectedProjectID,
              environment: environment.isEmpty ? nil : environment,
              kind: selectedKind,
              environmentVariableName: environmentVariableName.isEmpty
                ? nil : environmentVariableName,
              allowedHosts: hosts.isEmpty ? nil : hosts
            )
            dismiss()
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            label.isEmpty || service.isEmpty || secret.isEmpty
              || (!environmentVariableName.isEmpty
                && !ApprovedCommandRunner.isValidEnvironmentVariable(environmentVariableName)))
        }
      }
      .padding(24)
      .frame(width: 500)
    }
  }

  struct ApprovalView: View {
    @EnvironmentObject private var model: AppModel
    let request: AgentRequest

    var body: some View {
      VStack(alignment: .leading, spacing: 16) {
        Label("\(request.agentDisplayName) wants access", systemImage: "key.fill")
          .font(.title2.bold())

        switch request.kind {
        case .command: commandDetails
        case .httpRequest: httpDetails
        case .environment: environmentDetails
        }

        Divider()
        Text(footnote)
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack {
          Button("Deny") { model.decide(.deny) }
          Spacer()
          Button("Allow Once") { model.decide(.allowOnce) }
            .buttonStyle(.borderedProminent)
        }
      }
      .padding(24)
      .frame(width: 600)
    }

    @ViewBuilder private var credentialRows: some View {
      if let credential = model.credentialSummary(for: request) {
        LabeledContent("Credential", value: credential.label)
        LabeledContent("Service", value: credential.service)
      }
      LabeledContent("Project", value: request.projectPath)
      if let purpose = request.purpose, !purpose.isEmpty {
        LabeledContent("Purpose", value: purpose)
      }
    }

    @ViewBuilder private var commandDetails: some View {
      credentialRows
      if let operation = request.operation, !operation.isEmpty {
        monospacedBlock("Command", operation)
      }
      if let environmentVariable = request.environmentVariable {
        LabeledContent(
          "Delivery",
          value: request.deliveryMode == .tempFile
            ? "Protected temporary file path via \(environmentVariable)"
            : "Environment variable \(environmentVariable)")
      }
      riskWarning
    }

    @ViewBuilder private var httpDetails: some View {
      credentialRows
      monospacedBlock(
        "Request", "\(request.httpMethod ?? "GET") \(request.url ?? "")")
      if let host = request.url.flatMap({ URLComponents(string: $0)?.host }) {
        if request.hostAllowed == true {
          Label("\(host) is an allowed host for this credential", systemImage: "checkmark.shield")
            .font(.callout)
        } else {
          Label(
            "This credential has no host restriction. It will be sent to \(host).",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.callout)
          .foregroundStyle(.orange)
        }
      }
      if !request.headerNames.isEmpty {
        LabeledContent("Headers", value: request.headerNames.joined(separator: ", "))
      }
      if let body = request.bodyPreview, !body.isEmpty {
        monospacedBlock("Body", body)
      }
    }

    @ViewBuilder private var environmentDetails: some View {
      LabeledContent("Folder", value: request.projectPath)
      if let operation = request.operation {
        monospacedBlock("Command", operation)
      }
      LabeledContent(
        "Secrets", value: request.environmentVariables.joined(separator: ", "))
      riskWarning
    }

    @ViewBuilder private var riskWarning: some View {
      if let risk = model.riskAssessment(for: request), risk.level != .normal {
        VStack(alignment: .leading, spacing: 5) {
          Label(
            risk.level == .high ? "High-risk command" : "Review command",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.headline)
          ForEach(risk.reasons, id: \.self) { reason in
            Text("• \(reason)")
              .font(.caption)
          }
        }
      }
    }

    private func monospacedBlock(_ title: String, _ text: String) -> some View {
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Text(text)
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
      }
    }

    private var footnote: String {
      switch request.kind {
      case .command:
        return
          "The credential stays inside AgentKeyBox. After approval, AgentKeyBox runs this command locally and returns redacted output. A command can still transmit the credential over the network, so review the command before allowing it."
      case .httpRequest:
        return
          "AgentKeyBox sends this one HTTPS request itself and returns the redacted response. The agent never receives the credential, and redirects are not followed."
      case .environment:
        return
          "These secrets are handed to this command and everything it starts, in your terminal. AgentKeyBox cannot redact its output. Only allow commands you started yourself."
      }
    }
  }

  struct CredentialRequestView: View {
    @EnvironmentObject private var model: AppModel
    let prompt: CredentialRequestPrompt
    @State private var secret = ""

    var body: some View {
      VStack(alignment: .leading, spacing: 16) {
        Label("\(prompt.agentDisplayName) needs a credential", systemImage: "key.badge.plus")
          .font(.title2.bold())

        LabeledContent("Variable", value: prompt.environmentVariable)
        LabeledContent("Service", value: prompt.service)
        LabeledContent(
          "Project",
          value: prompt.existingProject?.name
            ?? "\(URL(fileURLWithPath: prompt.projectPath).lastPathComponent) (will be added)")
        if let purpose = prompt.purpose, !purpose.isEmpty {
          LabeledContent("Purpose", value: purpose)
        }
        if let hosts = prompt.preset?.allowedHosts, !hosts.isEmpty {
          LabeledContent("Allowed hosts", value: hosts.joined(separator: ", "))
        }

        if let link = prompt.preset?.dashboardURL, let url = URL(string: link) {
          Button("Open \(prompt.service) dashboard to get the key") {
            NSWorkspace.shared.open(url)
          }
        }

        SecureField("Paste the \(prompt.service) key here", text: $secret)

        Divider()
        Text(
          "The key is saved in your Keychain and never sent to \(prompt.agentDisplayName). The agent only learns that the credential now exists, and every use still needs your approval."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        HStack {
          Button("Cancel") { model.cancelCredentialRequest() }
          Spacer()
          Button("Save") { model.submitCredentialRequest(secret: secret) }
            .buttonStyle(.borderedProminent)
            .disabled(secret.isEmpty)
        }
      }
      .padding(24)
      .frame(width: 560)
    }
  }
#else
  import Foundation

  @main
  struct AgentKeyBoxApp {
    static func main() {
      print("AgentKeyBox is a macOS application. Core tests can run on this platform.")
    }
  }
#endif
