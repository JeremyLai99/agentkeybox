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
    @State private var projectToRemove: Project?

    var body: some View {
      NavigationSplitView {
        sidebar
          .navigationSplitViewColumnWidth(min: 200, ideal: 230)
          .confirmationDialog(
            L("Remove %@ from AgentKeyBox?", projectToRemove?.name ?? L("project")),
            isPresented: Binding(
              get: { projectToRemove != nil },
              set: { if !$0 { projectToRemove = nil } }),
            titleVisibility: .visible,
            presenting: projectToRemove
          ) { project in
            Button(L("Remove Project"), role: .destructive) { model.removeProject(project) }
            Button(L("Cancel"), role: .cancel) {}
          } message: { project in
            let count = model.credentials(in: .project(project.id)).count
            Text(
              count == 0
                ? L("Files in the project folder are not changed.")
                : count == 1
                  ? L(
                    "Its key is deleted from your Keychain, and agents can no longer use it. Files in the project folder are not changed."
                  )
                  : L(
                    "Its %@ keys are deleted from your Keychain, and agents can no longer use them. Files in the project folder are not changed.",
                    "\(count)")
            )
          }
      } detail: {
        if model.projects.isEmpty {
          EmptyStateView(isDropTargeted: isDropTargeted, chooseFolder: chooseProjectFolder)
        } else if let selection = model.selection {
          ProjectDetailView(
            item: selection,
            addKey: { addingKey = true },
            edit: { editing = EditRequest(credentialID: $0, showAdvanced: $1) })
        } else {
          Text(L("Choose a project")).foregroundStyle(.secondary)
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
        L("Which project should this key belong to?"),
        isPresented: Binding(
          get: { fileNeedingProject != nil },
          set: { if !$0 { fileNeedingProject = nil } }),
        presenting: fileNeedingProject
      ) { url in
        ForEach(model.projects) { project in
          Button(project.name) { model.importFile(url, projectID: project.id) }
        }
        Button(L("Every project")) { model.importFile(url, projectID: nil) }
        Button(L("Cancel"), role: .cancel) {}
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
        Section(L("Projects")) {
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
            .contextMenu {
              Button(L("Show in Finder")) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.rootPath)
              }
              Divider()
              Button(L("Remove Project…"), role: .destructive) { projectToRemove = project }
            }
          }
        }
        Section(L("Everywhere")) {
          HStack {
            Label(L("Global keys"), systemImage: "globe")
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
            Label(L("Add Project…"), systemImage: "plus")
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
      panel.prompt = L("Set Up")
      panel.message = L("Choose your project folder. AgentKeyBox will find the keys in it.")
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
        Label(L("Claude Code connected"), systemImage: "circle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .labelStyle(StatusDotLabelStyle(color: .green))
      } else if model.claudeConnectionStatus == "Not installed" {
        EmptyView()
      } else {
        Button(L("Connect Claude Code")) { model.connectClaudeCode() }
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
        Text(L("Drop your project folder here"))
          .font(.title.bold())
        Text(
          L(
            "AgentKeyBox finds the keys in it, keeps them in your Keychain, and connects Claude Code. Your coding agent then asks before it uses one."
          )
        )
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 440)
        Button(L("Choose Folder…"), action: chooseFolder)
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
      case .project(let id): return model.projects.first { $0.id == id }?.name ?? L("Project")
      case .global: return L("Global keys")
      }
    }

    private var subtitle: String {
      let count = keys.count
      let keyText = count == 1 ? L("1 key") : L("%@ keys", "\(count)")
      switch item {
      case .project:
        return model.claudeConnectionStatus == "Connected"
          ? L("%@ · Claude Code can ask for them", keyText) : keyText
      case .global:
        return L("%@ · available to every project", keyText)
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
              Label(L("Add Key"), systemImage: "plus")
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
              Text(L("No keys yet")).font(.headline)
              Text(L("Drop a .env or key file here, or use Add Key."))
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
            Text(L("Drop files or another project folder anywhere in this window."))
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

    private var attention: CredentialCardText.Attention? { CredentialCardText.attention(for: key) }

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          CredentialIcon(kind: key.kind, size: 30)
          VStack(alignment: .leading, spacing: 2) {
            Text(key.service.isEmpty ? key.label : L(key.service))
              .font(.headline)
              .lineLimit(1)
            Text(key.label)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        if let includes = ProviderBundles.includes(for: key) {
          Text(includes)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if let attention {
          Text(attention.message).font(.callout).foregroundStyle(.orange)
          Button(attention.action) { edit(key.id, attention.opensAdvanced) }
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
        Button(L("Edit…")) { edit(key.id, false) }
        Divider()
        Button(L("Delete…"), role: .destructive) { confirmingDelete = true }
      }
      .confirmationDialog(
        L("Delete %@?", key.label), isPresented: $confirmingDelete, titleVisibility: .visible
      ) {
        Button(L("Delete Key"), role: .destructive) { model.deleteCredential(key) }
      } message: {
        Text(L("The key is removed from your Keychain. Agents can no longer ask for it."))
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
    @State private var settings: [String: String]
    @State private var confirmingDelete = false

    private var preset: ProviderPreset? { ProviderCatalog.preset(for: credential) }

    init(credential: CredentialMetadata, showAdvanced: Bool) {
      self.credential = credential
      _name = State(initialValue: credential.label)
      _projectID = State(initialValue: credential.projectID)
      _showAdvanced = State(initialValue: showAdvanced)
      // Older keys have no stored variable and inject as their label; show what really happens.
      _variable = State(initialValue: credential.injectionVariableName ?? "")
      _hosts = State(initialValue: credential.allowedHosts ?? [])
      _settings = State(initialValue: credential.settings ?? [:])
    }

    private var variableIsValid: Bool {
      variable.isEmpty || ApprovedCommandRunner.isAllowedInjectionTarget(variable)
    }

    private var settingsAreValid: Bool {
      (preset?.settings ?? []).allSatisfy { setting in
        let value = (settings[setting.variable] ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty || setting.isValid(value)
      }
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 10) {
          CredentialIcon(kind: credential.kind, size: 32)
          Text(credential.service.isEmpty ? credential.label : L(credential.service))
            .font(.title2.bold())
        }

        Form {
          TextField(L("Name"), text: $name)
          Picker(L("Project"), selection: $projectID) {
            ForEach(model.projects) { project in
              Text(project.name).tag(Optional(project.id))
            }
            Text(L("Every project")).tag(UUID?.none)
          }
          LabeledContent(L("Key")) {
            if replacingKey {
              SecureField(L("Paste the new key"), text: $newKey)
            } else {
              HStack {
                Text("••••••••••••").foregroundStyle(.secondary)
                Button(L("Paste New Key…")) { replacingKey = true }
              }
            }
          }
          if let preset, !preset.settings.isEmpty {
            ProviderSettingsFields(preset: preset, settings: $settings)
          }
        }
        .formStyle(.columns)

        DisclosureGroup(L("Advanced"), isExpanded: $showAdvanced) {
          Form {
            if !credential.isFileCredential {
              LabeledContent(L("Injects as")) {
                TextField(L("Injects as"), text: $variable, prompt: Text("STRIPE_SECRET_KEY"))
                  .labelsHidden()
                  .font(.body.monospaced())
              }
              if !variableIsValid {
                Text(L("Use letters, digits, and _ only, and not PATH, HOME, or DYLD_*."))
                  .font(.caption)
                  .foregroundStyle(.orange)
              }
            }
            LabeledContent(L("Can be sent to")) {
              VStack(alignment: .leading, spacing: 6) {
                if hosts.isEmpty {
                  Text(L("Any website")).foregroundStyle(.orange)
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
                    .help(L("Remove %@", host))
                  }
                }
                HStack {
                  TextField(L("Add website"), text: $newHost, prompt: Text("api.example.com"))
                    .labelsHidden()
                    .onSubmit(addHost)
                  Button(L("Add"), action: addHost)
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
          Button(L("Delete…"), role: .destructive) { confirmingDelete = true }
          Spacer()
          Button(L("Cancel")) { dismiss() }
            .keyboardShortcut(.cancelAction)
          Button(L("Save")) {
            if model.updateCredential(
              credential.id, label: name, projectID: projectID, environmentVariableName: variable,
              allowedHosts: hosts, settings: settings, newSecret: replacingKey ? newKey : nil)
            {
              dismiss()
            }
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(
            name.isEmpty || !variableIsValid || !settingsAreValid
              || (replacingKey && newKey.isEmpty))
        }
      }
      .padding(24)
      .frame(width: 520)
      .confirmationDialog(
        L("Delete %@?", credential.label), isPresented: $confirmingDelete,
        titleVisibility: .visible
      ) {
        Button(L("Delete Key"), role: .destructive) {
          model.deleteCredential(credential)
          dismiss()
        }
      } message: {
        Text(L("The key is removed from your Keychain. Agents can no longer ask for it."))
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
    @State private var settings: [String: String] = [:]
    @State private var chosenProjectID: UUID?

    init(projectID: UUID?) {
      self.projectID = projectID
      _chosenProjectID = State(initialValue: projectID)
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 14) {
        Text(L("Add a Key")).font(.title2.bold())
        Form {
          Picker(L("Service"), selection: $preset) {
            Text(L("Other")).tag(ProviderPreset?.none)
            ForEach(ProviderCatalog.all.filter { $0.defaultKind != .json && $0.defaultKind != .p8 })
            { preset in
              Text(preset.displayName).tag(Optional(preset))
            }
          }
          .onChange(of: preset) { _, preset in
            settings = [:]
            guard let preset else { return }
            name = preset.environmentKeys.first ?? preset.displayName
            variable = preset.environmentKeys.first ?? ""
            hostsText = preset.allowedHosts.joined(separator: ", ")
          }
          TextField(L("Name"), text: $name, prompt: Text(verbatim: "STRIPE_SECRET_KEY"))
          SecureField(L("Key"), text: $key, prompt: Text(L("Paste the key")))
          if let preset, !preset.settings.isEmpty {
            ProviderSettingsFields(preset: preset, settings: $settings)
          }
          Picker(L("Project"), selection: $chosenProjectID) {
            ForEach(model.projects) { project in
              Text(project.name).tag(Optional(project.id))
            }
            Text(L("Every project")).tag(UUID?.none)
          }
        }
        .formStyle(.columns)

        if let link = preset?.dashboardURL, let url = URL(string: link) {
          Button(L("Get your %@ key", preset?.displayName ?? "")) { NSWorkspace.shared.open(url) }
            .buttonStyle(.link)
        }

        DisclosureGroup(L("Advanced"), isExpanded: $showAdvanced) {
          Form {
            LabeledContent(L("Injects as")) {
              TextField(L("Injects as"), text: $variable, prompt: Text("STRIPE_SECRET_KEY"))
                .labelsHidden()
                .font(.body.monospaced())
            }
            TextField(L("Can be sent to"), text: $hostsText, prompt: Text("api.stripe.com"))
          }
          .formStyle(.columns)
          .padding(.top, 6)
        }

        HStack {
          Spacer()
          Button(L("Cancel")) { dismiss() }
            .keyboardShortcut(.cancelAction)
          Button(L("Save")) {
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
              allowedHosts: hosts.isEmpty ? nil : hosts,
              settings: settings.mapValues { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.value.isEmpty })
            dismiss()
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(
            name.isEmpty || key.isEmpty
              || (!variable.isEmpty && !ApprovedCommandRunner.isAllowedInjectionTarget(variable))
              || !(preset?.settings ?? []).allSatisfy { setting in
                let value = (settings[setting.variable] ?? "").trimmingCharacters(in: .whitespaces)
                return value.isEmpty || setting.isValid(value)
              })
        }
      }
      .padding(24)
      .frame(width: 480)
    }
  }

  /// A provider's non-secret settings (Key ID, Issuer ID, Project URL) as form rows, each with a
  /// hint when the value does not look right, and one link to where the values are shown.
  struct ProviderSettingsFields: View {
    let preset: ProviderPreset
    @Binding var settings: [String: String]

    var body: some View {
      ForEach(preset.settings, id: \.variable) { setting in
        LabeledContent(L(setting.label)) {
          VStack(alignment: .leading, spacing: 4) {
            TextField(
              L(setting.label), text: binding(setting.variable),
              prompt: Text(setting.required ? setting.example : L("Optional"))
            )
            .labelsHidden()
            .font(.body.monospaced())
            let value = (settings[setting.variable] ?? "").trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, !setting.isValid(value) {
              Text(L("Should look like %@", setting.example))
                .font(.caption)
                .foregroundStyle(.orange)
            }
          }
        }
      }
      if let link = preset.settings.first(where: \.required)?.helpURL, let url = URL(string: link) {
        LabeledContent("") {
          Button(preset.settings.count == 1 ? L("Where do I find this?") : L("Where do I find these?")) {
            NSWorkspace.shared.open(url)
          }
          .buttonStyle(.link)
        }
      }
    }

    private func binding(_ variable: String) -> Binding<String> {
      Binding(
        get: { settings[variable] ?? "" },
        set: { settings[variable] = $0 })
    }
  }

  /// Settings (⌘,): agent connections, Keychain mode, and recent access.
  struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
      Form {
        Section(L("Language")) {
          Picker(L("Language"), selection: $model.languagePreference) {
            ForEach(LanguagePreference.allCases) { language in
              Text(language.displayName).tag(language)
            }
          }
          Text(L("Menus that come from macOS, such as Edit and Window, switch the next time AgentKeyBox opens."))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Section(L("Coding agents")) {
          agentRow("Claude Code", status: model.claudeConnectionStatus) {
            model.connectClaudeCode()
          }
          agentRow("Codex", status: model.codexConnectionStatus) { model.connectCodex() }
        }
        if model.activeSessionCount > 0 {
          Section(L("This session")) {
            HStack {
              Text(
                model.activeSessionCount == 1
                  ? L("Not asking again in 1 agent session")
                  : L("Not asking again in %@ agent sessions", "\(model.activeSessionCount)"))
              Spacer()
              Button(L("Ask Every Time")) { model.revokeSessionApprovals() }
            }
          }
        }
        Section(L("Security")) {
          Text(model.keychainStatus)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(L(model.brokerStatus)).foregroundStyle(.secondary)
        }
        Section(L("Recent access")) {
          if model.accessLog.isEmpty {
            Text(L("No requests yet")).foregroundStyle(.secondary)
          }
          ForEach(model.accessLog.prefix(15)) { event in
            HStack {
              Text("\(event.agentDisplayName) → \(event.credentialLabel)")
              Spacer()
              Text(
                event.decision == .deny
                  ? L("Denied")
                  : event.decision == .allowSession ? L("Allowed (session)") : L("Allowed"))
                .foregroundStyle(event.decision == .deny ? .orange : .secondary)
              Text(event.timestamp, style: .relative)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .font(.callout)
          }
        }
        #if DEBUG
          Section(L("Development")) {
            Button(L("Simulate Claude Request")) { model.simulateRequest() }
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
          Label(L("Connected"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if status == "Not installed" {
          Text(L("Not installed")).foregroundStyle(.secondary)
        } else {
          Button(L("Connect"), action: connect)
        }
      }
    }
  }
#endif
