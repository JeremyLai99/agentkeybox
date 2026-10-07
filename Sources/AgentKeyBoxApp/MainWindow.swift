#if os(macOS)
  import SwiftUI
  import AppKit
  import UniformTypeIdentifiers
  import AgentKeyBoxCore

  /// What the sidebar shows: one project, or keys available to every project.
  enum SidebarItem: Hashable {
    case project(UUID)
    case global
  }

  /// The main window: projects on the left, the selected project's keys on the right.
  struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTargeted = false
    @State private var addingKey = false
    @State private var editing: EditRequest?
    @State private var fileNeedingProject: URL?

    var body: some View {
      NavigationSplitView {
        sidebar
          .navigationSplitViewColumnWidth(min: 200, ideal: 230)
      } detail: {
        if model.projects.isEmpty {
          EmptyStateView(isDropTargeted: isDropTargeted, chooseFolder: chooseProjectFolder)
        } else if let selection = model.selection {
          ProjectDetailView(
            item: selection,
            addKey: { addingKey = true },
            edit: { editing = EditRequest(credentialID: $0, showAdvanced: $1) })
        } else {
          Text("Choose a project").foregroundStyle(.secondary)
        }
      }
      .sheet(isPresented: $addingKey) {
        AddKeyView(projectID: model.selectedProjectID)
          .environmentObject(model)
      }
      .sheet(item: $editing) { request in
        if let credential = model.credentials.first(where: { $0.id == request.credentialID }) {
          EditCredentialView(credential: credential, showAdvanced: request.showAdvanced)
            .environmentObject(model)
        }
      }
      .sheet(item: $model.pendingEnvImport) { preview in
        EnvImportView(preview: preview)
          .environmentObject(model)
      }
      .sheet(item: $model.pendingSetup) { plan in
        SetupView(plan: plan)
          .environmentObject(model)
      }
      .confirmationDialog(
        "Which project should this key belong to?",
        isPresented: Binding(
          get: { fileNeedingProject != nil },
          set: { if !$0 { fileNeedingProject = nil } }),
        presenting: fileNeedingProject
      ) { url in
        ForEach(model.projects) { project in
          Button(project.name) { model.importFile(url, projectID: project.id) }
        }
        Button("Every project") { model.importFile(url, projectID: nil) }
        Button("Cancel", role: .cancel) {}
      } message: { url in
        Text(url.lastPathComponent)
      }
      // A folder anywhere on the window sets up a project; a file goes into the selected one.
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
        model.selectFirstProjectIfNeeded()
      }
    }

    private var sidebar: some View {
      List(selection: $model.selection) {
        Section("Projects") {
          ForEach(model.projects) { project in
            HStack {
              Label(project.name, systemImage: "folder")
              Spacer()
              Text("\(model.credentials(in: .project(project.id)).count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .tag(SidebarItem.project(project.id))
            .help(project.rootPath)
          }
        }
        Section("Everywhere") {
          HStack {
            Label("Global keys", systemImage: "globe")
            Spacer()
            Text("\(model.credentials(in: .global).count)")
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
          .tag(SidebarItem.global)
        }
      }
      .safeAreaInset(edge: .bottom) {
        VStack(alignment: .leading, spacing: 8) {
          Button {
            chooseProjectFolder()
          } label: {
            Label("Add Project…", systemImage: "plus")
          }
          .buttonStyle(.borderless)
          AgentStatusRow()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }

    private func handleDrop(_ url: URL) {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return
      }
      if isDirectory.boolValue {
        model.beginSetup(folder: url)
      } else if let selection = model.selection {
        // One step: the file goes into the project the user is looking at.
        model.importFile(url, projectID: selection.projectID)
      } else {
        fileNeedingProject = url
      }
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
  }

  struct EditRequest: Identifiable {
    var id: UUID { credentialID }
    var credentialID: UUID
    var showAdvanced: Bool
  }

  extension SidebarItem {
    var projectID: UUID? {
      if case .project(let id) = self { return id }
      return nil
    }
  }

  /// Agent connection at the bottom of the sidebar: a quiet status, or one button to fix it.
  struct AgentStatusRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
      if model.claudeConnectionStatus == "Connected" {
        Label("Claude Code connected", systemImage: "circle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .labelStyle(StatusDotLabelStyle(color: .green))
      } else if model.claudeConnectionStatus == "Not installed" {
        EmptyView()
      } else {
        Button("Connect Claude Code") { model.connectClaudeCode() }
          .controlSize(.small)
      }
    }
  }

  struct StatusDotLabelStyle: LabelStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 7, height: 7)
        configuration.title
      }
    }
  }

  /// First run: one thing to do.
  struct EmptyStateView: View {
    @EnvironmentObject private var model: AppModel
    var isDropTargeted: Bool
    var chooseFolder: () -> Void

    var body: some View {
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
        Button("Choose Folder…", action: chooseFolder)
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
  }

  /// One project's keys as cards. Quiet unless a key needs attention.
  struct ProjectDetailView: View {
    @EnvironmentObject private var model: AppModel
    let item: SidebarItem
    let addKey: () -> Void
    let edit: (UUID, Bool) -> Void

    private var keys: [CredentialMetadata] { model.credentials(in: item) }

    private var title: String {
      switch item {
      case .project(let id): return model.projects.first { $0.id == id }?.name ?? "Project"
      case .global: return "Global keys"
      }
    }

    private var subtitle: String {
      let count = keys.count
      let keyText = count == 1 ? "1 key" : "\(count) keys"
      switch item {
      case .project:
        return model.claudeConnectionStatus == "Connected"
          ? "\(keyText) · Claude Code can ask for them" : keyText
      case .global:
        return "\(keyText) · available to every project"
      }
    }

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text(title).font(.largeTitle.bold())
              Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: addKey) {
              Label("Add Key", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
          }

          if let message = model.statusMessage {
            Text(message)
              .font(.callout)
              .foregroundStyle(.secondary)
          }

          if keys.isEmpty {
            VStack(spacing: 8) {
              Text("No keys yet").font(.headline)
              Text("Drop a .env or key file here, or use Add Key.")
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
            .background {
              RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.secondary.opacity(0.4))
            }
          } else {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)],
              alignment: .leading,
              spacing: 12
            ) {
              ForEach(keys) { key in
                KeyCard(key: key, edit: edit)
              }
            }
            Text("Drop files or another project folder anywhere in this window.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(28)
      }
    }
  }

  struct KeyCard: View {
    @EnvironmentObject private var model: AppModel
    let key: CredentialMetadata
    let edit: (UUID, Bool) -> Void
    @State private var confirmingDelete = false

    private var attention: String? { CredentialCardText.attention(for: key) }

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          CredentialIcon(kind: key.kind, size: 30)
          VStack(alignment: .leading, spacing: 2) {
            Text(key.service.isEmpty ? key.label : key.service)
              .font(.headline)
              .lineLimit(1)
            Text(key.label)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        if let attention {
          Text(attention).font(.callout).foregroundStyle(.orange)
          Button("Limit to one website…") { edit(key.id, true) }
            .buttonStyle(.link)
        } else {
          Text(CredentialCardText.usage(model.lastUse(of: key.id)))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.background, in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(attention == nil ? Color.secondary.opacity(0.25) : .orange, lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 12))
      .onTapGesture(count: 2) { edit(key.id, false) }
      .contextMenu {
        Button("Edit…") { edit(key.id, false) }
        Divider()
        Button("Delete…", role: .destructive) { confirmingDelete = true }
      }
      .confirmationDialog(
        "Delete \(key.label)?", isPresented: $confirmingDelete, titleVisibility: .visible
      ) {
        Button("Delete Key", role: .destructive) { model.deleteCredential(key) }
      } message: {
        Text("The key is removed from your Keychain. Agents can no longer ask for it.")
      }
    }
  }

  /// Name, project, and replacing the key. Technical fields stay under Advanced.
  struct EditCredentialView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let credential: CredentialMetadata
    @State private var name: String
    @State private var projectID: UUID?
    @State private var replacingKey = false
    @State private var newKey = ""
    @State private var showAdvanced: Bool
    @State private var variable: String
    @State private var hosts: [String]
    @State private var newHost = ""
    @State private var confirmingDelete = false

    init(credential: CredentialMetadata, showAdvanced: Bool) {
      self.credential = credential
      _name = State(initialValue: credential.label)
      _projectID = State(initialValue: credential.projectID)
      _showAdvanced = State(initialValue: showAdvanced)
      // Older keys have no stored variable and inject as their label; show what really happens.
      _variable = State(initialValue: credential.injectionVariableName ?? "")
      _hosts = State(initialValue: credential.allowedHosts ?? [])
    }

    private var variableIsValid: Bool {
      variable.isEmpty || ApprovedCommandRunner.isAllowedInjectionTarget(variable)
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 10) {
          CredentialIcon(kind: credential.kind, size: 32)
          Text(credential.service.isEmpty ? credential.label : credential.service)
            .font(.title2.bold())
        }

        Form {
          TextField("Name", text: $name)
          Picker("Project", selection: $projectID) {
            ForEach(model.projects) { project in
              Text(project.name).tag(Optional(project.id))
            }
            Text("Every project").tag(UUID?.none)
          }
          LabeledContent("Key") {
            if replacingKey {
              SecureField("Paste the new key", text: $newKey)
            } else {
              HStack {
                Text("••••••••••••").foregroundStyle(.secondary)
                Button("Paste New Key…") { replacingKey = true }
              }
            }
          }
        }
        .formStyle(.columns)

        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
          Form {
            if !credential.isFileCredential {
              LabeledContent("Injects as") {
                TextField("Injects as", text: $variable, prompt: Text("STRIPE_SECRET_KEY"))
                  .labelsHidden()
                  .font(.body.monospaced())
              }
              if !variableIsValid {
                Text("Use letters, digits, and _ only, and not PATH, HOME, or DYLD_*.")
                  .font(.caption)
                  .foregroundStyle(.orange)
              }
            }
            LabeledContent("Can be sent to") {
              VStack(alignment: .leading, spacing: 6) {
                if hosts.isEmpty {
                  Text("Any website").foregroundStyle(.orange)
                }
                ForEach(hosts, id: \.self) { host in
                  HStack {
                    Text(host).font(.body.monospaced())
                    Button {
                      hosts.removeAll { $0 == host }
                    } label: {
                      Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(host)")
                  }
                }
                HStack {
                  TextField("Add website", text: $newHost, prompt: Text("api.example.com"))
                    .labelsHidden()
                    .onSubmit(addHost)
                  Button("Add", action: addHost)
                    .disabled(normalizedHost(newHost) == nil)
                }
              }
            }
          }
          .formStyle(.columns)
          .padding(.top, 6)
        }

        Divider()
        HStack {
          Button("Delete…", role: .destructive) { confirmingDelete = true }
          Spacer()
          Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
          Button("Save") {
            if model.updateCredential(
              credential.id, label: name, projectID: projectID, environmentVariableName: variable,
              allowedHosts: hosts, newSecret: replacingKey ? newKey : nil)
            {
              dismiss()
            }
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(name.isEmpty || !variableIsValid || (replacingKey && newKey.isEmpty))
        }
      }
      .padding(24)
      .frame(width: 520)
      .confirmationDialog(
        "Delete \(credential.label)?", isPresented: $confirmingDelete, titleVisibility: .visible
      ) {
        Button("Delete Key", role: .destructive) {
          model.deleteCredential(credential)
          dismiss()
        }
      } message: {
        Text("The key is removed from your Keychain. Agents can no longer ask for it.")
      }
    }

    private func addHost() {
      guard let host = normalizedHost(newHost), !hosts.contains(host) else { return }
      hosts.append(host)
      newHost = ""
    }

    /// Accepts "api.stripe.com", "https://api.stripe.com/v1", or "*.supabase.co".
    private func normalizedHost(_ text: String) -> String? {
      let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
      guard !trimmed.isEmpty else { return nil }
      if trimmed.hasPrefix("*.") { return trimmed.contains(" ") ? nil : trimmed }
      let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
      guard let host = URLComponents(string: candidate)?.host, host.contains(".") else {
        return nil
      }
      return host
    }
  }

  /// Pick the service, paste the key, save. Everything else is filled in from the service.
  struct AddKeyView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID?
    @State private var preset: ProviderPreset?
    @State private var name = ""
    @State private var key = ""
    @State private var showAdvanced = false
    @State private var variable = ""
    @State private var hostsText = ""
    @State private var chosenProjectID: UUID?

    init(projectID: UUID?) {
      self.projectID = projectID
      _chosenProjectID = State(initialValue: projectID)
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 14) {
        Text("Add a Key").font(.title2.bold())
        Form {
          Picker("Service", selection: $preset) {
            Text("Other").tag(ProviderPreset?.none)
            ForEach(ProviderCatalog.all.filter { $0.defaultKind != .json && $0.defaultKind != .p8 })
            { preset in
              Text(preset.displayName).tag(Optional(preset))
            }
          }
          .onChange(of: preset) { _, preset in
            guard let preset else { return }
            name = preset.environmentKeys.first ?? preset.displayName
            variable = preset.environmentKeys.first ?? ""
            hostsText = preset.allowedHosts.joined(separator: ", ")
          }
          TextField("Name", text: $name, prompt: Text("STRIPE_SECRET_KEY"))
          SecureField("Key", text: $key, prompt: Text("Paste the key"))
          Picker("Project", selection: $chosenProjectID) {
            ForEach(model.projects) { project in
              Text(project.name).tag(Optional(project.id))
            }
            Text("Every project").tag(UUID?.none)
          }
        }
        .formStyle(.columns)

        if let link = preset?.dashboardURL, let url = URL(string: link) {
          Button("Get your \(preset?.displayName ?? "") key") { NSWorkspace.shared.open(url) }
            .buttonStyle(.link)
        }

        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
          Form {
            LabeledContent("Injects as") {
              TextField("Injects as", text: $variable, prompt: Text("STRIPE_SECRET_KEY"))
                .labelsHidden()
                .font(.body.monospaced())
            }
            TextField("Can be sent to", text: $hostsText, prompt: Text("api.stripe.com"))
          }
          .formStyle(.columns)
          .padding(.top, 6)
        }

        HStack {
          Spacer()
          Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
          Button("Save") {
            let hosts = hostsText.split(whereSeparator: { $0 == "," || $0.isWhitespace })
              .map { $0.lowercased() }
            let resolvedVariable =
              variable.isEmpty && ApprovedCommandRunner.isAllowedInjectionTarget(name)
              ? name : variable
            model.addCredential(
              label: name,
              service: preset?.displayName ?? ProviderCatalog.inferService(fromEnvironmentKey: name),
              secret: Data(key.utf8),
              projectID: chosenProjectID,
              kind: preset?.defaultKind ?? .apiKey,
              environmentVariableName: resolvedVariable.isEmpty ? nil : resolvedVariable,
              allowedHosts: hosts.isEmpty ? nil : hosts)
            dismiss()
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(
            name.isEmpty || key.isEmpty
              || (!variable.isEmpty && !ApprovedCommandRunner.isAllowedInjectionTarget(variable)))
        }
      }
      .padding(24)
      .frame(width: 480)
    }
  }

  /// Settings (⌘,): agent connections, Keychain mode, and recent access.
  struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
      Form {
        Section("Coding agents") {
          agentRow("Claude Code", status: model.claudeConnectionStatus) {
            model.connectClaudeCode()
          }
          agentRow("Codex", status: model.codexConnectionStatus) { model.connectCodex() }
        }
        Section("Security") {
          Text(model.keychainStatus)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(model.brokerStatus).foregroundStyle(.secondary)
        }
        Section("Recent access") {
          if model.accessLog.isEmpty {
            Text("No requests yet").foregroundStyle(.secondary)
          }
          ForEach(model.accessLog.prefix(15)) { event in
            HStack {
              Text("\(event.agentDisplayName) → \(event.credentialLabel)")
              Spacer()
              Text(event.decision == .deny ? "Denied" : "Allowed")
                .foregroundStyle(event.decision == .deny ? .orange : .secondary)
              Text(event.timestamp, style: .relative)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .font(.callout)
          }
        }
        #if DEBUG
          Section("Development") {
            Button("Simulate Claude Request") { model.simulateRequest() }
              .disabled(model.credentials.isEmpty)
          }
        #endif
      }
      .formStyle(.grouped)
      .frame(width: 520, height: 520)
      .task { model.refreshAgentStatuses() }
    }

    private func agentRow(_ name: String, status: String, connect: @escaping () -> Void)
      -> some View
    {
      HStack {
        Text(name)
        Spacer()
        if status == "Connected" {
          Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if status == "Not installed" {
          Text("Not installed").foregroundStyle(.secondary)
        } else {
          Button("Connect", action: connect)
        }
      }
    }
  }
#endif
