#if os(macOS)
  import AgentKeyBoxCore
  import AppKit
  import SwiftUI
  import UniformTypeIdentifiers

  struct SensitiveItemKind: Identifiable {
    let kind: CredentialKind
    var id: String { kind.rawValue }
  }

  /// Native, authenticated editing. Raw values never enter the broker or metadata.
  struct SensitiveItemView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let kind: CredentialKind
    let original: CredentialMetadata?
    @State private var name: String
    @State private var projectID: UUID?
    @State private var destination: String
    @State private var linkedLoginID: UUID?
    @State private var initializedLink = false
    @State private var loadedMetadata: CredentialMetadata?
    @State private var number = ""
    @State private var cardholder = ""
    @State private var month = ""
    @State private var year = ""
    @State private var codes: RecoveryCodeSet?
    @State private var username = ""
    @State private var password = ""
    @State private var loaded: Bool
    @State private var working = false
    @State private var errorMessage: String?
    @State private var confirmingStatuses = false
    @State private var statusesChanged = false

    init(kind: CredentialKind, projectID: UUID?, original: CredentialMetadata? = nil) {
      self.kind = kind
      self.original = original
      _name = State(initialValue: original?.label ?? "")
      _projectID = State(initialValue: projectID)
      _destination = State(
        initialValue: kind == .login ? original?.loginURL ?? "" : original?.submissionURL ?? "")
      _linkedLoginID = State(initialValue: original?.linkedLoginID)
      _loaded = State(initialValue: original == nil)
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 14) {
        Label(
          L(kind.protectedTitle),
          systemImage: kind == .login
            ? "globe" : kind == .creditCard ? "creditcard" : "lock.rectangle.on.rectangle"
        )
        .font(.title2.bold())
        if loaded {
          ScrollView {
            VStack(alignment: .leading, spacing: 14) {
              Form {
                TextField(L("Name"), text: $name)
                Picker(L("Project"), selection: $projectID) {
                  ForEach(model.projects) { project in
                    Text(project.name).tag(Optional(project.id))
                  }
                  Text(L("Every project")).tag(UUID?.none)
                }
                if kind == .recoveryCodes {
                  Picker(L("Linked website login"), selection: $linkedLoginID) {
                    Text(L("Not linked")).tag(UUID?.none)
                    ForEach(availableLogins) { login in
                      Text(login.label).tag(Optional(login.id))
                    }
                  }
                }
                if linkedLoginID == nil {
                  TextField(
                    kind == .login ? L("Sign-in page") : L("Submission destination"),
                    text: $destination,
                    prompt: Text(
                      verbatim: kind == .login
                        ? "https://example.com/login" : "https://example.com/submit"))
                }
              }
              .formStyle(.columns)
              if linkedLoginID == nil, kind != .login {
                ForEach(siteSuggestions, id: \.origin) { suggestion in
                  Button {
                    destination = suggestion.origin + "/"
                  } label: {
                    Label(
                      L("Use this site: %@ (%@)", suggestion.origin, suggestion.label),
                      systemImage: "globe")
                  }
                  .buttonStyle(.link)
                }
                if !siteSuggestions.isEmpty {
                  Text(L("Add the page path after the site address, for example /checkout."))
                    .font(.caption).foregroundStyle(.secondary)
                }
              }
              Text(
                L(
                  linkedLoginID != nil
                    ? "When this website asks for a recovery code during sign-in, this set will be used automatically."
                    : "The name and website are visible to agents. Leave the website empty to keep this item unavailable for use."
                )
              )
              .font(.caption).foregroundStyle(.secondary)
              if kind == .login {
                Form {
                  SecureField(L("Username or email"), text: $username)
                  SecureField(L("Password"), text: $password)
                }.formStyle(.columns)
              } else if kind == .creditCard {
                Form {
                  SecureField(L("Card number"), text: $number)
                  SecureField(L("Cardholder"), text: $cardholder)
                  TextField(L("Expiration month"), text: $month, prompt: Text(verbatim: "MM"))
                  TextField(L("Expiration year"), text: $year, prompt: Text(verbatim: "YYYY"))
                }
                .formStyle(.columns)
                Text(L("The security code (CVV) is not stored."))
                  .font(.caption).foregroundStyle(.secondary)
              } else {
                recoveryFields
              }
              Text(
                L(
                  kind == .login
                    ? "Approve sign-in in AgentKeyBox. The agent can read page text and request same-site links for up to 15 minutes. Supported recovery-code pages require a separate approval. JavaScript sign-in, SSO and TOTP are not supported."
                    : kind == .recoveryCodes
                      ? linkedLoginID != nil
                        ? "Each use requires approval and marks one code Issued before sending. Failures never automatically restore availability."
                        : "For browser use, this exact URL must match the recovery form submission destination. Each use requires approval and marks one code Issued before sending. Failures never automatically restore availability. No GitHub compatibility has been verified."
                      : "Each use requires approval. AgentKeyBox sends selected fields directly to this exact destination and returns only a fixed result. Browser sessions and checkout automation are not supported yet."
                )
              )
              .font(.callout).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }
          }
          .frame(maxHeight: 510)
          .disabled(working)
        } else {
          Text(L("Unlock to edit this protected item."))
            .foregroundStyle(.secondary)
          Button(L("Unlock")) { Task { await load() } }.disabled(working)
        }
        if let errorMessage {
          Text(errorMessage).font(.callout).foregroundStyle(.red)
        }
        HStack {
          if working { ProgressView().controlSize(.small) }
          Spacer()
          Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
          Button(L("Save")) {
            if statusesChanged { confirmingStatuses = true } else { save() }
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(
            !loaded || working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .padding(24)
      .frame(width: 560)
      .interactiveDismissDisabled(working)
      .onAppear {
        guard !initializedLink else { return }
        initializedLink = true
        if original == nil, kind == .recoveryCodes, availableLogins.count == 1 {
          linkedLoginID = availableLogins.first?.id
        }
      }
      .onChange(of: availableLogins.map(\.id)) { _, ids in
        if let linkedLoginID, !ids.contains(linkedLoginID) { self.linkedLoginID = nil }
      }
      .confirmationDialog(
        L("Save recovery-code status changes?"), isPresented: $confirmingStatuses,
        titleVisibility: .visible
      ) {
        Button(L("Save")) { save() }
        Button(L("Cancel"), role: .cancel) {}
      } message: {
        Text(
          L(
            "Only mark a code Available after verifying that it was not consumed. AgentKeyBox cannot check this with the service."
          ))
      }
    }

    /// Sites of this project's saved website logins, offered as one-click starting points.
    /// The user still sees and finishes the exact destination before saving.
    private var siteSuggestions: [(origin: String, label: String)] {
      var seen = Set<String>()
      return availableLogins.compactMap { login in
        guard let url = try? BrowserPolicy.loginURL(login.loginURL),
          let origin = BrowserPolicy.origin(url), seen.insert(origin).inserted,
          destination != origin + "/"
        else { return nil }
        return (origin, login.label)
      }
    }

    private var availableLogins: [CredentialMetadata] {
      BrowserRecoveryPolicy.logins(in: model.credentials, projectID: projectID)
    }

    private var recoveryFields: some View {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Button(L("Paste Codes")) {
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            importCodes(text)
          }
          Button(L("Import Code File…")) { importFile() }
        }
        Text(
          L(
            "One code per line. Import replaces the set; matching codes keep their previous status."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
        if let codes {
          Text(L("%@ recovery codes", "\(codes.entries.count)")).font(.headline)
          ForEach(Array(codes.entries.enumerated()), id: \.element.id) { index, entry in
            Picker(
              L("Code %@", "\(index + 1)"),
              selection: Binding(
                get: { self.codes?.entries.first { $0.id == entry.id }?.status ?? entry.status },
                set: {
                  self.codes?.setStatus($0, for: entry.id)
                  statusesChanged = true
                })
            ) {
              ForEach(RecoveryCodeSet.Status.allCases, id: \.self) { status in
                Text(statusLabel(status)).tag(status)
              }
            }
          }
          Text(
            L(
              "Issued codes are not reused automatically, even after an error or restart. Restored codes need review."
            )
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
    }

    private func statusLabel(_ status: RecoveryCodeSet.Status) -> String {
      switch status {
      case .available: return L("Available")
      case .issued: return L("Issued — result unverified")
      case .used: return L("Used")
      case .needsReview: return L("Needs review")
      }
    }

    private func importCodes(_ text: String) {
      do {
        var replacement = try RecoveryCodeSet(text: text)
        if let codes { replacement.preserveHistory(from: codes) }
        codes = replacement
        errorMessage = nil
      } catch {
        errorMessage = SensitiveDataError.invalidCodes.localizedDescription
      }
    }

    private func importFile() {
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.plainText]
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      guard panel.runModal() == .OK, let url = panel.url else { return }
      do {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 64 * 1024 else {
          throw SensitiveDataError.invalidCodes
        }
        importCodes(try String(contentsOf: url, encoding: .utf8))
      } catch {
        errorMessage = L("Could not read this recovery-code file.")
      }
    }

    private func load() async {
      guard let original else { return }
      working = true
      defer { working = false }
      do {
        let snapshot = try await model.loadSensitiveItem(original)
        let payload = snapshot.payload
        loadedMetadata = snapshot.metadata
        if let card = payload.card {
          number = card.number
          cardholder = card.cardholder
          month = String(card.expirationMonth)
          year = String(card.expirationYear)
        }
        codes = payload.recoveryCodes
        username = payload.login?.username ?? ""
        password = payload.login?.password ?? ""
        loaded = true
        errorMessage = nil
      } catch {
        errorMessage = L("Could not unlock this item. Close the editor and try again.")
      }
    }

    private func save() {
      do {
        let endpoint =
          linkedLoginID == nil
          ? destination.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if !endpoint.isEmpty {
          if kind == .login {
            _ = try BrowserPolicy.loginURL(endpoint)
          } else {
            _ = try SensitiveSubmissionPolicy.destination(endpoint)
          }
        }
        let payload: SensitivePayload
        if kind == .login {
          payload = SensitivePayload(login: try StoredLogin(username: username, password: password))
        } else if kind == .creditCard {
          payload = SensitivePayload(
            card: try StoredCard(
              number: number, cardholder: cardholder,
              expirationMonth: Int(month) ?? 0, expirationYear: Int(year) ?? 0))
        } else {
          guard let codes else { throw SensitiveDataError.invalidCodes }
          payload = SensitivePayload(recoveryCodes: codes)
        }
        working = true
        errorMessage = nil
        Task {
          let saved = await model.saveSensitiveItem(
            original: loadedMetadata ?? original, label: name,
            projectID: projectID, destination: endpoint, payload: payload,
            linkedLoginID: linkedLoginID)
          working = false
          if saved {
            dismiss()
          } else {
            errorMessage = L("Could not save this protected item. Close the editor and try again.")
          }
        }
      } catch {
        errorMessage =
          (error as? SensitiveDataError)?.localizedDescription
          ?? L("Could not save this protected item. Check its fields and try again.")
      }
    }
  }
#endif
