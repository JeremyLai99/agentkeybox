#if os(macOS)
  import SwiftUI
  import AppKit
  import UniformTypeIdentifiers
  import AgentKeyBoxCore

  @main
  struct AgentKeyBoxApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
      // A single main window, so the menu bar's "Open AgentKeyBox" brings it back instead of
      // opening duplicates.
      Window("AgentKeyBox", id: "main") {
        ContentView()
          .environmentObject(model)
          .frame(minWidth: 860, minHeight: 560)
          .tint(.agentKeyBlue)
      }

      MenuBarExtra {
        MenuBarContent()
          .environmentObject(model)
      } label: {
        MenuBarLabel(pending: model.hasPendingPrompt)
      }
    }
  }

  extension Color {
    /// BRAND.md primary accent.
    static let agentKeyBlue = Color(red: 0x08 / 255, green: 0x67 / 255, blue: 0xE8 / 255)
  }

  /// Brand images from `assets/brand`. Release builds load them from `Contents/Resources/Brand`
  /// (copied by build-release-macos.sh); debug builds run from SwiftPM's build directory and fall
  /// back to the repository checkout. Main-actor isolated because NSImage is not Sendable and
  /// only SwiftUI views use these images.
  @MainActor
  enum BrandAssets {
    static func url(_ relativePath: String) -> URL? {
      if let resources = Bundle.main.resourceURL {
        let url = resources.appendingPathComponent("Brand/\(relativePath)")
        if FileManager.default.fileExists(atPath: url.path) { return url }
      }
      #if DEBUG
        let repository = URL(fileURLWithPath: #filePath)
          .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appendingPathComponent("assets/brand/\(relativePath)")
        if FileManager.default.fileExists(atPath: url.path) { return url }
      #endif
      return nil
    }

    /// Combines `<name>-<points>.png` and `<name>-<2×points>.png` into one 1x/2x image.
    static func image(_ directory: String, _ name: String, points: Int, template: Bool = false)
      -> NSImage?
    {
      let image = NSImage(size: NSSize(width: points, height: points))
      for scale in [1, 2] {
        guard let url = url("\(directory)/\(name)-\(points * scale).png"),
          let representation = NSImageRep(contentsOf: url)
        else { continue }
        representation.size = NSSize(width: points, height: points)
        image.addRepresentation(representation)
      }
      guard !image.representations.isEmpty else { return nil }
      image.isTemplate = template
      return image
    }

    static let menuBar = image("menu-bar", "MenuBarTemplate", points: 18, template: true)
    static let approvalRequest = image("ui", "ApprovalRequest", points: 64)

    static func credentialIcon(for kind: CredentialKind) -> NSImage? {
      let name: String
      switch kind {
      case .apiKey, .token: name = "Credential-APIKey"
      case .environmentVariable: name = "Credential-ENV"
      case .p8: name = "Credential-P8"
      case .pem: name = "Credential-PEM"
      case .json: name = "Credential-JSON"
      }
      return image("credential-types", name, points: 32)
    }
  }

  struct MenuBarLabel: View {
    let pending: Bool

    var body: some View {
      if let icon = BrandAssets.menuBar {
        // A template image, so macOS tints it for light, dark, and highlighted menu bars.
        Image(nsImage: icon)
      } else {
        Image(systemName: "key.horizontal.fill")
      }
      if pending {
        Text("1")
      }
    }
  }

  struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
      if let title = model.pendingPromptTitle {
        Button("Review: \(title)") { model.bringPromptToFront() }
      } else {
        Text("No pending requests")
      }

      if !model.accessEvents.isEmpty {
        Divider()
        Text("Recent")
        ForEach(model.accessEvents.prefix(5)) { event in
          Text("\(event.agentDisplayName) → \(event.credentialLabel) · \(event.decision.rawValue)")
        }
      }

      Divider()
      Button("Open AgentKeyBox") {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
      }
      Button("Quit AgentKeyBox") { NSApp.terminate(nil) }
        .keyboardShortcut("q")
    }
  }

  /// A credential-type glyph from the brand set, with an SF Symbol fallback.
  struct CredentialIcon: View {
    let kind: CredentialKind
    var size: CGFloat = 22

    var body: some View {
      if let icon = BrandAssets.credentialIcon(for: kind) {
        Image(nsImage: icon)
          .resizable()
          .interpolation(.high)
          .frame(width: size, height: size)
      } else {
        Image(systemName: "key.fill")
          .frame(width: size, height: size)
      }
    }
  }

  /// The branded request glyph (BRAND.md reserves it for approval UI), with an SF Symbol fallback.
  struct ApprovalGlyph: View {
    var size: CGFloat = 40

    var body: some View {
      if let icon = BrandAssets.approvalRequest {
        Image(nsImage: icon)
          .resizable()
          .interpolation(.high)
          .frame(width: size, height: size)
      } else {
        Image(systemName: "key.fill")
          .font(.system(size: size * 0.6))
          .frame(width: size, height: size)
      }
    }
  }

  /// Hosts approval prompts in a floating panel that is independent of the main window.
  @MainActor
  final class PromptPanelController {
    private var panel: NSPanel?

    func show<Content: View>(_ content: Content, title: String) {
      let panel = self.panel ?? makePanel()
      self.panel = panel
      panel.title = title
      let hosting = NSHostingController(rootView: content)
      // Size the panel from the view's ideal size instead of a fixed frame.
      hosting.sizingOptions = [.preferredContentSize]
      panel.contentViewController = hosting
      panel.center()
      NSApp.activate(ignoringOtherApps: true)
      panel.makeKeyAndOrderFront(nil)
    }

    func close() {
      panel?.orderOut(nil)
      panel?.contentViewController = nil
    }

    private func makePanel() -> NSPanel {
      // Not closable: the user answers with Allow / Deny (or Save / Cancel), and an unanswered
      // prompt times out, so there is no ambiguous "closed" state.
      let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
      panel.level = .floating
      panel.isReleasedWhenClosed = false
      panel.hidesOnDeactivate = false
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      return panel
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

  /// A scanned project folder awaiting the user's one confirmation.
  struct SetupPlan: Identifiable {
    struct AgentOffer: Identifiable {
      var id: String
      var name: String
      var status: AgentIntegrationStatus
    }

    let id = UUID()
    var scan: ProjectScan
    /// Installed coding agents; ones not yet connected are offered, preselected.
    var agents: [AgentOffer]
  }

  /// Parsed `.env` entries awaiting the user's selection. Values stay in memory only until the
  /// import is confirmed or cancelled.
  struct EnvImportPreview: Identifiable {
    struct Entry: Identifiable {
      var id: String { key }
      var key: String
      var value: String
      var selected: Bool
      var updatesExisting: Bool
    }

    let id = UUID()
    var fileName: String
    var projectID: UUID?
    var entries: [Entry]
  }

  @MainActor
  final class AppModel: ObservableObject {
    @Published var projects: [Project]
    @Published var credentials: [CredentialMetadata]
    @Published var pendingRequest: AgentRequest? {
      didSet { updatePromptPanel() }
    }
    @Published var pendingCredentialRequest: CredentialRequestPrompt? {
      didSet { updatePromptPanel() }
    }
    @Published var pendingEnvImport: EnvImportPreview?
    @Published var pendingSetup: SetupPlan?
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
    private let promptPanel = PromptPanelController()
    private var brokerServer: LocalBrokerServer?
    private var pendingBrokerContinuation: CheckedContinuation<BrokerResponse, Never>?
    private var pendingBrokerRequest: BrokerRequest?
    private var pendingApprovalTimeoutTask: Task<Void, Never>?
    private var decisionInProgress = false
    /// Claimed synchronously before the first suspension point so concurrent broker requests
    /// cannot both pass the "nothing pending" check while the main actor is re-entered.
    private var approvalSlotReserved = false

    init() {
      let (snapshot, quarantined) = metadataStore.loadWithRecovery()
      self.projects = snapshot.projects
      self.credentials = snapshot.credentials
      if let quarantined {
        self.statusMessage =
          "AgentKeyBox could not read its project list and moved it to \(quarantined.lastPathComponent). Your secrets are still in the Keychain."
      }

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

    /// Parses a `.env` file and shows which entries will be imported; nothing is stored until
    /// the user confirms in `confirmEnvImport`.
    func importEnv(at url: URL, projectID: UUID?) {
      do {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = EnvParser.parse(text).filter { !$0.value.isEmpty }
        guard !parsed.isEmpty else {
          statusMessage = "No environment variables were found in that file."
          return
        }
        pendingEnvImport = EnvImportPreview(
          fileName: url.lastPathComponent,
          projectID: projectID,
          entries: parsed.keys.sorted().map { key in
            EnvImportPreview.Entry(
              key: key,
              value: parsed[key] ?? "",
              selected: EnvImportClassifier.looksSecret(key: key, value: parsed[key] ?? ""),
              updatesExisting: existingCredential(named: key, projectID: projectID) != nil)
          })
      } catch {
        statusMessage = "Could not import .env: \(error.localizedDescription)"
      }
    }

    func confirmEnvImport(selectedKeys: Set<String>) {
      guard let preview = pendingEnvImport else { return }
      pendingEnvImport = nil
      let chosen = preview.entries.filter { selectedKeys.contains($0.key) }
      guard !chosen.isEmpty else {
        statusMessage = "Nothing was imported."
        return
      }
      guard
        let result = storeEnvSecrets(
          chosen.map { ($0.key, $0.value) }, projectID: preview.projectID)
      else { return }
      statusMessage =
        "Imported \(result.added) new and updated \(result.updated) existing secret(s) from \(preview.fileName)."
    }

    /// Saves `.env` entries for a project. An entry whose variable already exists in that
    /// project updates the stored value instead of creating a duplicate. Returns nil (and sets
    /// the status message) if nothing could be saved.
    private func storeEnvSecrets(_ entries: [(key: String, value: String)], projectID: UUID?)
      -> (added: Int, updated: Int)?
    {
      var added: [CredentialMetadata] = []
      var updated = 0
      do {
        for entry in entries {
          if let existing = existingCredential(named: entry.key, projectID: projectID),
            let index = credentials.firstIndex(where: { $0.id == existing.id })
          {
            try secretStore.save(secret: Data(entry.value.utf8), id: existing.id)
            credentials[index].updatedAt = Date()
            updated += 1
            continue
          }
          let preset = ProviderCatalog.preset(matchingService: nil, environmentKey: entry.key)
          let metadata = CredentialMetadata(
            label: entry.key,
            service: ProviderCatalog.inferService(fromEnvironmentKey: entry.key),
            projectID: projectID,
            kind: .environmentVariable,
            environmentVariableName: entry.key,
            allowedHosts: preset.flatMap { $0.allowedHosts.isEmpty ? nil : $0.allowedHosts }
          )
          try secretStore.save(secret: Data(entry.value.utf8), id: metadata.id)
          added.append(metadata)
        }
      } catch {
        for metadata in added { try? secretStore.delete(id: metadata.id) }
        statusMessage = "Could not save keys: \(error.localizedDescription)"
        return nil
      }

      credentials.append(contentsOf: added)
      guard persistMetadata() else {
        let addedIDs = Set(added.map(\.id))
        credentials.removeAll { addedIDs.contains($0.id) }
        for metadata in added { try? secretStore.delete(id: metadata.id) }
        return nil
      }
      return (added.count, updated)
    }

    // MARK: - One-step project setup

    /// Scans a dropped project folder and shows the setup sheet. Nothing is stored until the
    /// user presses Set Up.
    func beginSetup(folder: URL) {
      statusMessage = "Looking for keys in \(folder.lastPathComponent)…"
      Task {
        let scan = await Task.detached(priority: .userInitiated) {
          ProjectScanner.scan(folder)
        }.value
        var agents: [SetupPlan.AgentOffer] = []
        for adapter in [ClaudeCodeAdapter() as any AgentAdapter, CodexAdapter()] {
          let status = await adapter.integrationStatus()
          if status != .notInstalled {
            agents.append(.init(id: adapter.id, name: adapter.displayName, status: status))
          }
        }
        self.statusMessage = nil
        self.pendingSetup = SetupPlan(scan: scan, agents: agents)
      }
    }

    func cancelSetup() {
      pendingSetup = nil
    }

    func performSetup(
      _ plan: SetupPlan,
      secrets selectedSecrets: Set<String>,
      keyFiles selectedFiles: Set<String>,
      ignoreEnvFiles: Bool,
      connect agentIDs: Set<String>
    ) {
      pendingSetup = nil
      let scan = plan.scan
      guard let project = addProject(name: scan.projectName, rootPath: scan.root.path) else {
        return
      }
      var summary: [String] = []

      let chosenSecrets = scan.secrets.filter { selectedSecrets.contains($0.key) }
      if !chosenSecrets.isEmpty {
        guard
          let result = storeEnvSecrets(
            chosenSecrets.map { ($0.key, $0.value) }, projectID: project.id)
        else { return }
        summary.append("\(result.added + result.updated) key(s) saved")
      }

      var savedFiles = 0
      for file in scan.keyFiles where selectedFiles.contains(file.id) {
        if credentials.contains(where: { $0.projectID == project.id && $0.label == file.label }) {
          continue
        }
        guard let data = try? Data(contentsOf: file.url) else { continue }
        let hosts = ProviderCatalog.preset(matchingService: file.service, environmentKey: nil)?
          .allowedHosts ?? []
        if addCredential(
          label: file.label, service: file.service, secret: data, projectID: project.id,
          kind: file.kind, allowedHosts: hosts.isEmpty ? nil : hosts) != nil
        {
          savedFiles += 1
        }
      }
      if savedFiles > 0 { summary.append("\(savedFiles) key file(s) saved") }

      if ignoreEnvFiles, !scan.envFilesNotIgnored.isEmpty {
        do {
          try GitIgnore.addEntries(scan.envFilesNotIgnored, to: scan.root)
          summary.append("\(scan.envFilesNotIgnored.joined(separator: ", ")) added to .gitignore")
        } catch {
          summary.append("could not update .gitignore (\(error.localizedDescription))")
        }
      }

      for agent in plan.agents where agentIDs.contains(agent.id) {
        switch agent.id {
        case ClaudeCodeAdapter().id: connectClaudeCode()
        case CodexAdapter().id: connectCodex()
        default: break
        }
        summary.append("connecting \(agent.name)")
      }

      statusMessage =
        "\(project.name) is ready" + (summary.isEmpty ? "." : ": " + summary.joined(separator: ", ") + ".")
    }

    func cancelEnvImport() {
      pendingEnvImport = nil
    }

    private func existingCredential(named key: String, projectID: UUID?) -> CredentialMetadata? {
      credentials.first { $0.projectID == projectID && $0.injectionVariableName == key }
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

    #if DEBUG
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
    #endif

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

    /// - Parameter rememberHost: for a request to a host outside the key's list, also add that
    ///   host to the list once the user has authenticated.
    func decide(_ decision: ApprovalDecision, rememberHost: Bool = false) {
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

        if decision != .deny, rememberHost, let credential {
          self.rememberAllowedHost(for: request, credentialID: credential.id)
        }

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
        ApprovedCommandRunner.isAllowedInjectionTarget(environmentVariable)
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
      request.hostStatus = validated.hostStatus
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
        ApprovedCommandRunner.isAllowedInjectionTarget(variable)
      else {
        return BrokerResponse(
          ok: false,
          error: "env_var must be a valid, non-reserved environment variable name (not PATH, HOME, DYLD_*, …).")
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

    func approvalPresentation(for request: AgentRequest) -> ApprovalPresentation {
      ApprovalPresentation.make(
        for: request,
        credential: credentialSummary(for: request),
        projectName: projectName(containing: request.projectPath),
        risk: riskAssessment(for: request))
    }

    private func projectName(containing path: String) -> String {
      projects
        .filter { ProjectScopeResolver.contains(projectRoot: $0.rootPath, requestPath: path) }
        .max { normalize($0.rootPath).count < normalize($1.rootPath).count }?.name
        ?? URL(fileURLWithPath: path).lastPathComponent
    }

    private func rememberAllowedHost(for request: AgentRequest, credentialID: UUID) {
      guard let host = request.url.flatMap({ URLComponents(string: $0)?.host?.lowercased() }),
        let index = credentials.firstIndex(where: { $0.id == credentialID })
      else { return }
      var hosts = credentials[index].allowedHosts ?? []
      guard !hosts.contains(host) else { return }
      hosts.append(host)
      credentials[index].allowedHosts = hosts
      credentials[index].updatedAt = Date()
      persistMetadata()
    }

    var hasPendingPrompt: Bool {
      pendingRequest != nil || pendingCredentialRequest != nil
    }

    var pendingPromptTitle: String? {
      if let request = pendingRequest { return "\(request.agentDisplayName) wants access" }
      if let prompt = pendingCredentialRequest {
        return "\(prompt.agentDisplayName) needs a credential"
      }
      return nil
    }

    /// From the menu bar: re-show the pending prompt if it was hidden behind other windows.
    func bringPromptToFront() {
      updatePromptPanel()
    }

    /// Approval and credential prompts live in their own floating panel, so they appear even
    /// when the main window has been closed.
    private func updatePromptPanel() {
      if let request = pendingRequest {
        promptPanel.show(
          ApprovalView(request: request, presentation: approvalPresentation(for: request))
            .environmentObject(self).tint(.agentKeyBlue),
          title: "\(request.agentDisplayName) wants access")
      } else if let prompt = pendingCredentialRequest {
        promptPanel.show(
          CredentialRequestView(prompt: prompt).environmentObject(self).tint(.agentKeyBlue),
          title: "\(prompt.agentDisplayName) needs a credential")
      } else {
        promptPanel.close()
      }
    }

    func riskAssessment(for request: AgentRequest) -> CommandRiskAssessment? {
      guard request.kind != .httpRequest, let executablePath = request.executablePath else {
        return nil
      }
      return CommandRiskAnalyzer.assess(
        executablePath: executablePath, arguments: request.arguments,
        projectPath: request.projectPath)
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
    @State private var isDropTargeted = false

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
              HStack(spacing: 8) {
                CredentialIcon(kind: credential.kind)
                credentialRow(credential)
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
        detail
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
      .sheet(item: $model.pendingEnvImport) { preview in
        EnvImportView(preview: preview)
          .environmentObject(model)
      }
      .sheet(item: $model.pendingSetup) { plan in
        SetupView(plan: plan)
          .environmentObject(model)
      }
      // A folder anywhere on the window starts setup; a single file goes to import.
      .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          guard let url else { return }
          Task { @MainActor in handleDrop(url) }
        }
        return true
      }
      .overlay {
        if isDropTargeted, !model.projects.isEmpty {
          RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.agentKeyBlue, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .padding(8)
            .allowsHitTesting(false)
        }
      }
      .task {
        model.refreshAgentStatuses()
      }
    }

    private func handleDrop(_ url: URL) {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return
      }
      if isDirectory.boolValue {
        model.beginSetup(folder: url)
      } else if ProjectScanner.isEnvFile(url.lastPathComponent) {
        pendingImport = PendingImport(url: url, kind: .env)
      } else {
        pendingImport = PendingImport(url: url, kind: .credentialFile)
      }
    }

    private func credentialRow(_ credential: CredentialMetadata) -> some View {
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
    }

    @ViewBuilder private var detail: some View {
      if model.projects.isEmpty {
        emptyState
      } else {
        overview
      }
    }

    /// First run: one thing to do.
    private var emptyState: some View {
      VStack(spacing: 18) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 96, height: 96)
        Text("Drop your project folder here")
          .font(.title.bold())
        Text(
          "AgentKeyBox finds the keys in it, keeps them in your Keychain, and connects Claude Code. Your coding agent then asks before it uses one."
        )
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 440)
        Button("Choose Folder…") { chooseProjectFolder() }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
        if let message = model.statusMessage {
          Text(message).font(.callout).foregroundStyle(.secondary)
        }
      }
      .padding(40)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        RoundedRectangle(cornerRadius: 18)
          .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
          .foregroundStyle(isDropTargeted ? Color.agentKeyBlue : Color.secondary.opacity(0.35))
          .padding(24)
      }
    }

    private var overview: some View {
        VStack(spacing: 18) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 88, height: 88)
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

          #if DEBUG
            HStack {
              Button("Simulate Claude Request") { model.simulateRequest() }
                .disabled(model.credentials.isEmpty)
              Button("Simulate Codex Request") {
                model.simulateRequest(agentID: "codex", agentName: "Codex")
              }
              .disabled(model.credentials.isEmpty)
            }
          #endif

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

    private func chooseProjectFolder() {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.prompt = "Set Up"
      panel.message = "Choose your project folder. AgentKeyBox will find the keys in it."
      guard panel.runModal() == .OK, let url = panel.url else { return }
      model.beginSetup(folder: url)
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
                && !ApprovedCommandRunner.isAllowedInjectionTarget(environmentVariableName)))
        }
      }
      .padding(24)
      .frame(width: 500)
    }
  }

  struct ApprovalView: View {
    @EnvironmentObject private var model: AppModel
    let request: AgentRequest
    let presentation: ApprovalPresentation
    @State private var showDetails: Bool
    @State private var rememberHost = false

    init(request: AgentRequest, presentation: ApprovalPresentation) {
      self.request = request
      self.presentation = presentation
      _showDetails = State(initialValue: presentation.detailsExpanded)
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 12) {
          ApprovalGlyph(size: 44)
          VStack(alignment: .leading, spacing: 2) {
            Text(presentation.headline)
              .font(.title3.bold())
              .fixedSize(horizontal: false, vertical: true)
            if let subtitle = presentation.subtitle {
              Text(subtitle).foregroundStyle(.secondary)
            }
          }
        }

        if let warning = presentation.warning {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 2) {
              Text(warning.title).bold()
              Text(warning.message).fixedSize(horizontal: false, vertical: true)
            }
          }
          .font(.callout)
          .foregroundStyle(.orange)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }

        if !presentation.facts.isEmpty {
          Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(presentation.facts, id: \.label) { fact in
              GridRow {
                Text(fact.label).foregroundStyle(.secondary)
                Text(fact.value).fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }

        if let host = presentation.rememberableHost {
          Toggle("Always allow \(host) for this key", isOn: $rememberHost)
            .toggleStyle(.checkbox)
        }

        DisclosureGroup("Details", isExpanded: $showDetails) {
          // A ScrollView has no intrinsic height; the explicit minimum and ideal height keep it
          // from collapsing to zero inside the prompt panel.
          ScrollView {
            details
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 6)
          }
          .frame(minHeight: 120, idealHeight: 220, maxHeight: 280)
        }

        Divider()

        HStack {
          denyButton
          Spacer()
          Label("Touch ID next", systemImage: "touchid")
            .font(.caption)
            .foregroundStyle(.secondary)
          allowButton
        }
      }
      .padding(22)
      .frame(width: 520)
    }

    // Return triggers the default button: Allow for ordinary requests, Deny when the prompt
    // carries a warning. Escape denies ordinary requests.
    @ViewBuilder private var denyButton: some View {
      if presentation.denyIsDefault {
        Button("Deny") { model.decide(.deny) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      } else {
        Button("Deny") { model.decide(.deny) }
          .keyboardShortcut(.cancelAction)
      }
    }

    @ViewBuilder private var allowButton: some View {
      if presentation.denyIsDefault {
        // No keyboard shortcut: allowing a flagged request takes a deliberate click.
        Button("Allow Once") { model.decide(.allowOnce, rememberHost: rememberHost) }
      } else {
        Button("Allow Once") { model.decide(.allowOnce, rememberHost: rememberHost) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
    }

    @ViewBuilder private var details: some View {
      VStack(alignment: .leading, spacing: 10) {
        if let credential = model.credentialSummary(for: request) {
          LabeledContent("Key", value: credential.label)
        }
        LabeledContent("Folder", value: request.projectPath)
        switch request.kind {
        case .command:
          commandBlock
          if let variable = request.environmentVariable {
            LabeledContent(
              "Delivered as",
              value: request.deliveryMode == .tempFile
                ? "Temporary file path in \(variable)" : "Environment variable \(variable)")
          }
        case .httpRequest:
          monospacedBlock("Request", "\(request.httpMethod ?? "GET") \(request.url ?? "")")
          if !request.headerNames.isEmpty {
            LabeledContent("Headers", value: request.headerNames.joined(separator: ", "))
          }
          if let body = request.bodyPreview, !body.isEmpty {
            monospacedBlock("Body", body)
          }
        case .environment:
          commandBlock
        }
        if let risk = model.riskAssessment(for: request), risk.reasons.count > 1 {
          ForEach(risk.reasons, id: \.self) { reason in
            Text("• \(reason)").font(.caption)
          }
        }
        Text(footnote)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }

    /// One argument per line with control characters escaped and spaces quoted, so an argument
    /// cannot hide another behind newlines or masquerade as several arguments.
    @ViewBuilder private var commandBlock: some View {
      if let executable = request.executablePath {
        monospacedBlock(
          request.arguments.isEmpty ? "Command" : "Command and arguments (one per line)",
          CommandDisplay.lines(executable: executable, arguments: request.arguments))
      } else if let operation = request.operation, !operation.isEmpty {
        monospacedBlock("Command", operation)
      }
    }

    private func monospacedBlock(_ title: String, _ text: String) -> some View {
      VStack(alignment: .leading, spacing: 4) {
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
          "AgentKeyBox runs this command on your Mac and returns redacted output. The agent never sees the key, but the command itself could send it elsewhere."
      case .httpRequest:
        return
          "AgentKeyBox sends this one request itself and returns the redacted response. The agent never sees the key, and redirects are not followed."
      case .environment:
        return
          "The keys are handed to this command in your terminal and to anything it starts. Only allow commands you started yourself."
      }
    }
  }

  struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    let plan: SetupPlan
    @State private var secrets: Set<String>
    @State private var keyFiles: Set<String>
    @State private var ignoreEnvFiles = true
    @State private var connect: Set<String>

    init(plan: SetupPlan) {
      self.plan = plan
      _secrets = State(initialValue: Set(plan.scan.secrets.filter(\.looksSecret).map(\.key)))
      _keyFiles = State(initialValue: Set(plan.scan.keyFiles.map(\.id)))
      _connect = State(
        initialValue: Set(plan.agents.filter { $0.status != .configured }.map(\.id)))
    }

    private var foundNothing: Bool {
      plan.scan.secrets.isEmpty && plan.scan.keyFiles.isEmpty
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 14) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 52, height: 52)
          VStack(alignment: .leading, spacing: 2) {
            Text("Set up \(plan.scan.projectName)").font(.title2.bold())
            Text(
              foundNothing
                ? "No keys found in this folder. You can add them later."
                : "We found these in the folder. Likely secrets are already checked."
            )
            .foregroundStyle(.secondary)
          }
        }

        if !foundNothing {
          List {
            ForEach(plan.scan.secrets) { secret in
              row(
                isOn: binding(secret.key, in: $secrets),
                icon: .environmentVariable,
                title: secret.key,
                detail: secret.looksSecret ? secret.sourceFile : "\(secret.sourceFile) · setting")
            }
            ForEach(plan.scan.keyFiles) { file in
              row(
                isOn: binding(file.id, in: $keyFiles),
                icon: file.kind,
                title: file.label,
                detail: file.relativePath)
            }
          }
          .frame(minHeight: 160, idealHeight: 240, maxHeight: 300)
        }

        VStack(alignment: .leading, spacing: 8) {
          if !plan.scan.envFilesNotIgnored.isEmpty {
            Toggle(
              "Add \(plan.scan.envFilesNotIgnored.joined(separator: ", ")) to .gitignore so it isn't committed",
              isOn: $ignoreEnvFiles)
          }
          ForEach(plan.agents) { agent in
            if agent.status == .configured {
              Label("\(agent.name) is connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            } else {
              Toggle("Connect \(agent.name)", isOn: binding(agent.id, in: $connect))
            }
          }
        }
        .toggleStyle(.checkbox)

        Button {
          model.performSetup(
            plan, secrets: secrets, keyFiles: keyFiles, ignoreEnvFiles: ignoreEnvFiles,
            connect: connect)
        } label: {
          Text(foundNothing ? "Add Project" : "Set Up").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)

        HStack {
          Text("Keys move into your Keychain. Your files stay where they are.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Cancel") { model.cancelSetup() }
            .keyboardShortcut(.cancelAction)
        }
      }
      .padding(24)
      .frame(width: 560)
    }

    private func row(isOn: Binding<Bool>, icon: CredentialKind, title: String, detail: String)
      -> some View
    {
      Toggle(isOn: isOn) {
        HStack(spacing: 10) {
          CredentialIcon(kind: icon, size: 22)
          Text(title).font(.system(.body, design: .monospaced))
          Spacer()
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
      }
      .toggleStyle(.checkbox)
    }

    private func binding(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
      Binding(
        get: { set.wrappedValue.contains(id) },
        set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } })
    }
  }

  struct EnvImportView: View {
    @EnvironmentObject private var model: AppModel
    let preview: EnvImportPreview
    @State private var selected: Set<String>

    init(preview: EnvImportPreview) {
      self.preview = preview
      _selected = State(initialValue: Set(preview.entries.filter(\.selected).map(\.key)))
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 14) {
        Text("Import \(preview.fileName)").font(.title2.bold())
        Text(
          "Choose which entries are secrets. Likely secrets are preselected; settings such as PORT or NODE_ENV and public keys are not."
        )
        .font(.callout)
        .foregroundStyle(.secondary)

        List(preview.entries) { entry in
          Toggle(
            isOn: Binding(
              get: { selected.contains(entry.key) },
              set: { if $0 { selected.insert(entry.key) } else { selected.remove(entry.key) } }
            )
          ) {
            HStack {
              Text(entry.key).font(.system(.body, design: .monospaced))
              Spacer()
              Text(
                entry.updatesExisting
                  ? "updates existing · \(entry.value.count) chars" : "\(entry.value.count) chars"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          }
        }
        .frame(minHeight: 220)

        HStack {
          Button("Cancel") { model.cancelEnvImport() }
          Spacer()
          Button("Import \(selected.count)") { model.confirmEnvImport(selectedKeys: selected) }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)
        }
      }
      .padding(24)
      .frame(width: 560, height: 460)
    }
  }

  struct CredentialRequestView: View {
    @EnvironmentObject private var model: AppModel
    let prompt: CredentialRequestPrompt
    @State private var secret = ""

    var body: some View {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          ApprovalGlyph()
          Text("\(prompt.agentDisplayName) needs a credential")
            .font(.title2.bold())
        }

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
        .fixedSize(horizontal: false, vertical: true)

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
