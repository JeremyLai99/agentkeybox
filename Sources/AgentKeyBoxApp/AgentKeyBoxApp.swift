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

  @MainActor
  final class AppModel: ObservableObject {
    @Published var projects: [Project]
    @Published var credentials: [CredentialMetadata]
    @Published var pendingRequest: AgentRequest?
    @Published var statusMessage: String?
    @Published var brokerStatus: String = "Starting local broker…"
    @Published var claudeConnectionStatus: String = "Not checked"
    @Published var codexConnectionStatus: String = "Not checked"
    @Published var requireBiometricConfirmation: Bool = true
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

    func addProject(name: String, rootPath: String) {
      let normalizedPath = normalize(rootPath)
      guard !projects.contains(where: { normalize($0.rootPath) == normalizedPath }) else {
        statusMessage = "That project is already in AgentKeyBox."
        return
      }
      let project = Project(name: name, rootPath: normalizedPath)
      projects.append(project)
      guard persistMetadata() else {
        projects.removeAll { $0.id == project.id }
        return
      }
      statusMessage = "Project added."
    }

    func addCredential(
      label: String,
      service: String,
      secret: Data,
      projectID: UUID?,
      environment: String? = nil,
      kind: CredentialKind = .apiKey
    ) {
      let metadata = CredentialMetadata(
        label: label,
        service: service,
        projectID: projectID,
        environment: environment,
        kind: kind
      )
      do {
        try secretStore.save(secret: secret, id: metadata.id)
        credentials.append(metadata)
        guard persistMetadata() else {
          credentials.removeAll { $0.id == metadata.id }
          try? secretStore.delete(id: metadata.id)
          return
        }
        statusMessage = "Saved securely in Keychain."
      } catch {
        statusMessage = "Could not save secret: \(error.localizedDescription)"
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
            let metadata = CredentialMetadata(
              label: key,
              service: ProviderCatalog.inferService(fromEnvironmentKey: key),
              projectID: projectID,
              kind: .environmentVariable
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

    func credentialSummary(for request: AgentRequest) -> CredentialMetadata? {
      guard let id = UUID(uuidString: request.credentialIdentifier) else { return nil }
      return credentials.first { $0.id == id }
    }

    func decide(_ decision: ApprovalDecision) {
      guard !decisionInProgress else { return }
      guard let request = pendingRequest,
        let credentialID = UUID(uuidString: request.credentialIdentifier),
        let credential = credentials.first(where: { $0.id == credentialID })
      else {
        finishDecision(
          BrokerResponse(ok: false, error: "Credential was not found."),
          message: "Credential was not found."
        )
        return
      }

      decisionInProgress = true
      let brokerRequestAtDecision = pendingBrokerRequest
      let requestID = request.id

      Task {
        if decision != .deny && requireBiometricConfirmation {
          do {
            _ = try await authenticator.authenticateIfAvailable(
              reason: "Allow \(request.agentDisplayName) to use \(credential.label)?"
            )
          } catch {
            await MainActor.run {
              guard self.pendingRequest?.id == requestID else { return }
              self.finishDecision(
                BrokerResponse(ok: true, decision: .deny),
                message: "Local authentication cancelled or failed."
              )
            }
            return
          }
        }

        await approvalEngine.record(
          decision: decision,
          request: request,
          credentialLabel: credential.label
        )
        let recentHistory = Array((await approvalEngine.history()).prefix(20))
        await MainActor.run {
          self.accessEvents = recentHistory
        }

        if decision == .deny {
          await MainActor.run {
            guard self.pendingRequest?.id == requestID else { return }
            self.finishDecision(
              BrokerResponse(ok: true, decision: .deny),
              message: "Access denied."
            )
          }
          return
        }

        guard pendingRequest?.id == requestID else { return }

        guard let brokerRequest = brokerRequestAtDecision else {
          await MainActor.run {
            guard self.pendingRequest?.id == requestID else { return }
            self.finishDecision(
              BrokerResponse(ok: true, decision: decision),
              message: "Access approved: \(decision.rawValue)."
            )
          }
          return
        }

        let response = await executeApprovedBrokerRequest(
          brokerRequest,
          credentialID: credentialID,
          decision: decision
        )

        await MainActor.run {
          guard self.pendingRequest?.id == requestID else { return }
          self.finishDecision(
            response,
            message: response.ok
              ? "Approved command completed." : (response.error ?? "Approved command failed.")
          )
        }
      }
    }

    func refreshAgentStatuses() {
      Task {
        let claude = await ClaudeCodeAdapter().integrationStatus()
        let codex = await CodexAdapter().integrationStatus()
        await MainActor.run {
          self.claudeConnectionStatus = self.displayStatus(claude)
          self.codexConnectionStatus = self.displayStatus(codex)
        }
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
          await MainActor.run {
            update("Connected")
            self.statusMessage =
              "Connected AgentKeyBox to \(adapter.displayName). Start a new agent session to load the MCP tools."
          }
        } catch {
          await MainActor.run {
            update("Failed")
            self.statusMessage = error.localizedDescription
          }
        }
      }
    }

    private func handleBrokerRequest(_ brokerRequest: BrokerRequest) async -> BrokerResponse {
      switch brokerRequest.action {
      case .listCredentials:
        let visible = credentials.filter { credentialIsVisible($0, for: brokerRequest.projectPath) }
        return BrokerResponse(ok: true, credentials: visible.map(CredentialSummary.init(metadata:)))

      case .executeWithSecret:
        guard pendingBrokerContinuation == nil else {
          return BrokerResponse(
            ok: false, error: "Another AgentKeyBox approval is already pending.")
        }
        guard let identifier = brokerRequest.credentialIdentifier,
          let credentialID = UUID(uuidString: identifier),
          let credential = credentials.first(where: { $0.id == credentialID }),
          credentialIsVisible(credential, for: brokerRequest.projectPath)
        else {
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
          credentialIdentifier: identifier,
          purpose: brokerRequest.purpose,
          operation: operation,
          executablePath: brokerRequest.executablePath,
          arguments: brokerRequest.arguments ?? [],
          environmentVariable: brokerRequest.environmentVariable,
          deliveryMode: brokerRequest.deliveryMode,
          requestedScope: brokerRequest.requestedScope,
          sessionID: brokerRequest.sessionID
        )

        if let preauthorized = await approvalEngine.preauthorizedDecision(for: request),
          preauthorized != .deny
        {
          return await executeApprovedBrokerRequest(
            brokerRequest,
            credentialID: credentialID,
            decision: preauthorized
          )
        }

        pendingBrokerRequest = brokerRequest
        pendingRequest = request
        NSApp.activate(ignoringOtherApps: true)

        return await withCheckedContinuation { continuation in
          pendingBrokerContinuation = continuation
          pendingApprovalTimeoutTask?.cancel()
          let requestID = request.id
          pendingApprovalTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            await MainActor.run {
              guard let self, self.pendingRequest?.id == requestID else { return }
              self.finishDecision(
                BrokerResponse(ok: false, error: "Approval timed out."),
                message: "Approval timed out."
              )
            }
          }
        }
      }
    }

    private func executeApprovedBrokerRequest(
      _ brokerRequest: BrokerRequest,
      credentialID: UUID,
      decision: ApprovalDecision
    ) async -> BrokerResponse {
      guard let executablePath = brokerRequest.executablePath,
        let environmentVariable = brokerRequest.environmentVariable
      else {
        return BrokerResponse(ok: false, error: "Invalid approved execution request.")
      }

      let secret: Data
      do {
        guard let stored = try secretStore.read(id: credentialID) else {
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

    private func credentialIsVisible(_ metadata: CredentialMetadata, for projectPath: String)
      -> Bool
    {
      ProjectScopeResolver.isVisible(metadata, projects: projects, requestPath: projectPath)
    }

    private func finishDecision(_ response: BrokerResponse, message: String) {
      decisionInProgress = false
      pendingApprovalTimeoutTask?.cancel()
      pendingApprovalTimeoutTask = nil
      statusMessage = message
      finishBroker(response)
      pendingRequest = nil
      pendingBrokerRequest = nil
    }

    private func finishBroker(_ response: BrokerResponse) {
      let continuation = pendingBrokerContinuation
      pendingBrokerContinuation = nil
      continuation?.resume(returning: response)
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
      guard let executablePath = request.executablePath else { return nil }
      return CommandRiskAnalyzer.assess(
        executablePath: executablePath, arguments: request.arguments)
    }
  }

  struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAddCredential = false

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

          Toggle("Require Touch ID when available", isOn: $model.requireBiometricConfirmation)
            .toggleStyle(.switch)
            .frame(maxWidth: 320)

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
      .sheet(item: $model.pendingRequest) { request in
        ApprovalView(request: request)
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
      model.importEnv(at: url, projectID: model.projects.first?.id)
    }

    private func chooseCredentialFile() {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = false
      panel.canChooseFiles = true
      panel.allowsMultipleSelection = false
      panel.allowedContentTypes = []
      panel.prompt = "Import"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      model.importCredentialFile(at: url, projectID: model.projects.first?.id)
    }
  }

  struct AddCredentialView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var service = ""
    @State private var environment = ""
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
              if label.isEmpty, let key = preset.environmentKeys.first {
                label = key
              }
            }
          }
        }
        TextField("Label (e.g. Stripe Production)", text: $label)
        TextField("Service (e.g. Stripe)", text: $service)
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
            model.addCredential(
              label: label,
              service: service,
              secret: Data(secret.utf8),
              projectID: selectedProjectID,
              environment: environment.isEmpty ? nil : environment,
              kind: selectedKind
            )
            dismiss()
          }
          .buttonStyle(.borderedProminent)
          .disabled(label.isEmpty || service.isEmpty || secret.isEmpty)
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

        if let credential = model.credentialSummary(for: request) {
          LabeledContent("Credential", value: credential.label)
          LabeledContent("Service", value: credential.service)
        }
        LabeledContent("Project", value: request.projectPath)

        if let purpose = request.purpose, !purpose.isEmpty {
          LabeledContent("Purpose", value: purpose)
        }
        if let operation = request.operation, !operation.isEmpty {
          VStack(alignment: .leading, spacing: 5) {
            Text("Command").font(.caption).foregroundStyle(.secondary)
            Text(operation)
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
          }
        }
        if let environmentVariable = request.environmentVariable {
          LabeledContent(
            "Delivery",
            value: request.deliveryMode == .tempFile
              ? "Protected temporary file path via \(environmentVariable)"
              : "Environment variable \(environmentVariable)")
        }
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

        Divider()
        Text(
          "The credential stays inside AgentKeyBox. After approval, AgentKeyBox runs this command locally and returns redacted output. A command can still transmit the credential over the network, so review the command before allowing it."
        )
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
