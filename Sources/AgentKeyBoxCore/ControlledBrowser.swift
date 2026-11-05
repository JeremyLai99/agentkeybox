#if os(macOS)
  import Foundation
  import WebKit

  /// An offscreen, app-owned browser, never attached to an NSWindow/accessibility tree. The
  /// only observation channel is `read`; it is closed before authentication starts. No raw
  /// DOM, eval, screenshot, downloads, clipboard, dialogs, or cookie API is offered to agents.
  @MainActor
  public class ControlledBrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    public let id = UUID()
    public let credential: CredentialMetadata
    public private(set) var lease: BrowserLease
    public private(set) var submissionURL: URL?
    public private(set) var recoverySubmissionURL: URL?
    public let origin: String
    public var onClose: (() -> Void)?

    private var webView: WKWebView?
    private let loginURL: URL
    private var login: StoredLogin?
    private var recoveryCredential: CredentialMetadata?
    private var protectedValues: [String] = []
    private var links: [UUID: URL] = [:]
    private var navigationWaiter: CheckedContinuation<Void, Error>?
    private var navigationTimeout: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var allowedPost: URL?
    private var didNotifyClose = false
    private let world = WKContentWorld.world(name: "AgentKeyBox.private-browser")

    public init(credential: CredentialMetadata, owner: BrowserOwner) throws {
      guard credential.kind == .login else { throw ControlledBrowserError.unavailable }
      let url = try BrowserPolicy.loginURL(credential.loginURL)
      self.credential = credential
      loginURL = url
      origin = BrowserPolicy.origin(url)!
      lease = BrowserLease(owner: owner)
      super.init()
      expirationTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(BrowserPolicy.lifetime))
        guard !Task.isCancelled else { return }
        self?.close()
      }
    }

    public func authorize(_ owner: BrowserOwner) throws { try lease.authorize(owner) }

    /// Loads without any secrets; the native prompt subsequently names the actual POST target.
    public func prepare() async throws {
      do {
        try lease.authorize(lease.owner)
        guard lease.phase == .preparing else { throw ControlledBrowserError.busy }
        webView = try await makeWebView()
        try ensureOpen()
        try await navigate(to: loginURL)
        guard let target = try await script(BrowserScripts.inspect, as: String.self),
          let url = try? BrowserPolicy.loginURL(target), BrowserPolicy.permits(url, origin: origin)
        else { throw ControlledBrowserError.unsupportedForm }
        submissionURL = url
        try lease.transition(from: .preparing, to: .awaitingApproval)
      } catch {
        close()
        throw safe(error)
      }
    }

    /// Called only after native approval, local authentication, and metadata revision checks.
    public func signIn(payload: SensitivePayload) async throws -> BrowserPage {
      do {
        try lease.transition(from: .awaitingApproval, to: .authenticating)
        guard payload.kind == .login, payload.revision == credential.payloadRevision,
          let login = payload.login, let target = submissionURL
        else { throw ControlledBrowserError.unavailable }
        self.login = login
        protectedValues = [login.username, login.password]
        allowedPost = target
        try await submit(login, to: target)
        allowedPost = nil
        return try await refreshAfterSubmission(allowRecovery: true)
      } catch {
        close()
        throw safe(error)
      }
    }

    /// Selects an existing recovery set without reading any of its codes.
    /// The actual POST URL is shown only in native approval, never copied from agent input.
    public func prepareRecovery(credential: CredentialMetadata) throws -> URL {
      guard let target = recoverySubmissionURL else { throw ControlledBrowserError.unavailable }
      try BrowserRecoveryPolicy.validate(credential, target: target, origin: origin)
      try lease.transition(from: .recoveryRequired, to: .awaitingRecoveryApproval)
      recoveryCredential = credential
      return target
    }

    public func recover(
      credential: CredentialMetadata, payload: SensitivePayload,
      persistReservation: (Data) throws -> Void
    ) async throws -> BrowserPage {
      do {
        try lease.transition(from: .awaitingRecoveryApproval, to: .authenticating)
        guard let target = recoverySubmissionURL, recoveryCredential == credential else {
          throw ControlledBrowserError.unavailable
        }
        try BrowserRecoveryPolicy.validate(credential, target: target, origin: origin)
        // No suspension between reservation and persistence. Failure never fills the form.
        let code = try BrowserRecoveryPolicy.reserve(
          payload: payload, credential: credential, persist: persistReservation)
        protectedValues.append(code)
        allowedPost = target
        try await submitScript(
          BrowserScripts.submitRecovery,
          arguments: ["code": code, "destination": target.absoluteString])
        allowedPost = nil
        recoverySubmissionURL = nil
        recoveryCredential = nil
        // A second challenge or uncertain outcome closes the session; never try another code.
        return try await refreshAfterSubmission(allowRecovery: false)
      } catch {
        close()
        throw safe(error)
      }
    }

    private func recoveryPage() -> BrowserPage {
      BrowserPage(
        sessionID: id, status: "recoveryCodeRequired", origin: origin,
        title: "Recovery code required",
        text:
          "Request browser_recover with a stored recovery-code item. A separate native approval is required. No page content is available until verification completes.",
        links: [])
    }

    private func refreshAfterSubmission(allowRecovery: Bool) async throws -> BrowserPage {
      guard let oldView = webView, let landing = oldView.url,
        BrowserPolicy.permits(landing, origin: origin),
        !BrowserPolicy.containsSecret(landing.absoluteString, values: protectedValues)
      else { throw ControlledBrowserError.failed }
      // Discard the filled DOM, history, storage and content world before any observation.
      let cookies = await oldView.configuration.websiteDataStore.httpCookieStore.allCookies()
      try protectCookies(cookies)
      try ensureOpen()
      disposeWebView()
      let next = try await makeWebView()
      try ensureOpen()
      webView = next
      let host = loginURL.host!.lowercased()
      for cookie in cookies {
        let domain = cookie.domain.lowercased().trimmingCharacters(
          in: CharacterSet(charactersIn: "."))
        if host == domain || host.hasSuffix("." + domain) {
          await next.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
      }
      try ensureOpen()
      try await navigate(to: landing)
      if allowRecovery, let raw = try await script(BrowserScripts.inspectRecovery, as: String.self),
        let target = try? BrowserPolicy.loginURL(raw),
        BrowserPolicy.permits(target, origin: origin),
        !BrowserPolicy.containsSecret(raw, values: protectedValues)
      {
        recoverySubmissionURL = target
        links.removeAll()
        try lease.transition(from: .authenticating, to: .recoveryRequired)
        return recoveryPage()
      }
      try lease.transition(from: .authenticating, to: .ready)
      return try await read()
    }

    public func read() async throws -> BrowserPage {
      if lease.phase == .recoveryRequired {
        try ensureOpen()
        return recoveryPage()
      }
      // Busy is not fatal: a simultaneous read must not interrupt or observe a protected fill.
      try lease.transition(from: .ready, to: .reading)
      do {
        let page = try await snapshot()
        try lease.transition(from: .reading, to: .ready)
        return page
      } catch {
        close()
        throw safe(error)
      }
    }

    /// Returns only to the native approval UI. The agent uses an opaque link reference.
    public func destination(for linkID: UUID) throws -> URL {
      try lease.authorize(lease.owner)
      guard lease.phase == .ready else { throw ControlledBrowserError.busy }
      guard let url = links[linkID] else { throw ControlledBrowserError.invalidLink }
      return url
    }

    public func follow(linkID: UUID, approvedURL: URL) async throws -> BrowserPage {
      guard try destination(for: linkID) == approvedURL else {
        throw ControlledBrowserError.invalidLink
      }
      try lease.transition(from: .ready, to: .navigating)
      links.removeAll()
      do {
        try await navigate(to: approvedURL)
        try lease.transition(from: .navigating, to: .ready)
        return try await read()
      } catch {
        close()
        throw safe(error)
      }
    }

    public func close() {
      lease.close()
      expirationTask?.cancel()
      expirationTask = nil
      finishNavigation(.failure(ControlledBrowserError.unavailable))
      disposeWebView()
      login = nil
      protectedValues.removeAll()
      links.removeAll()
      submissionURL = nil
      recoverySubmissionURL = nil
      recoveryCredential = nil
      if !didNotifyClose {
        didNotifyClose = true
        onClose?()
      }
    }

    private func ensureOpen() throws { try lease.authorize(lease.owner) }

    private func safe(_ error: Error) -> ControlledBrowserError {
      (error as? ControlledBrowserError) ?? .failed
    }

    private func makeWebView() async throws -> WKWebView {
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.defaultWebpagePreferences.allowsContentJavaScript = false
      configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
      // No scripts, trackers, XHR, external images, CSS, fonts, media, or popups. Main-frame
      // navigation is separately restricted by the delegate. This intentionally supports
      // traditional HTML forms/pages, not JS applications or third-party sign-in widgets.
      let rules =
        #"[{"trigger":{"url-filter":".*","resource-type":["script","image","style-sheet","font","media","raw","svg-document","popup"]},"action":{"type":"block"}}]"#
      guard
        let rule = try await WKContentRuleListStore.default().compileContentRuleList(
          forIdentifier: "AgentKeyBox-controlled-browser-v1", encodedContentRuleList: rules)
      else { throw ControlledBrowserError.failed }
      configuration.userContentController.add(rule)
      let view = WKWebView(
        frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
      view.isInspectable = false
      view.navigationDelegate = self
      view.uiDelegate = self
      view.allowsBackForwardNavigationGestures = false
      return view
    }

    private func disposeWebView() {
      guard let view = webView else { return }
      webView = nil
      view.navigationDelegate = nil
      view.uiDelegate = nil
      view.stopLoading()
      view.configuration.userContentController.removeAllUserScripts()
      // Each instance owns a non-persistent store. Releasing it also releases its private data.
    }

    private func navigate(to url: URL) async throws {
      try ensureOpen()
      guard BrowserPolicy.permits(url, origin: origin), let view = webView else {
        throw ControlledBrowserError.invalidWebsite
      }
      try await withCheckedThrowingContinuation { continuation in
        beginNavigation(continuation)
        view.load(
          URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
      }
    }

    private func submit(_ login: StoredLogin, to target: URL) async throws {
      try await submitScript(
        BrowserScripts.submit,
        arguments: [
          "username": login.username, "password": login.password,
          "destination": target.absoluteString,
        ])
    }

    private func submitScript(_ source: String, arguments: [String: Any]) async throws {
      try await withCheckedThrowingContinuation { continuation in
        beginNavigation(continuation)
        Task {
          do {
            let result = try await script(source, as: Bool.self, arguments: arguments)
            guard result == true else {
              finishNavigation(.failure(ControlledBrowserError.unsupportedForm))
              return
            }
          } catch { finishNavigation(.failure(ControlledBrowserError.failed)) }
        }
      }
    }

    private func beginNavigation(_ continuation: CheckedContinuation<Void, Error>) {
      navigationWaiter = continuation
      navigationTimeout?.cancel()
      navigationTimeout = Task { [weak self] in
        try? await Task.sleep(for: .seconds(30))
        guard !Task.isCancelled else { return }
        self?.close()
      }
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
      navigationTimeout?.cancel()
      navigationTimeout = nil
      let waiter = navigationWaiter
      navigationWaiter = nil
      waiter?.resume(with: result)
    }

    private func script<T: Decodable & Sendable>(
      _ source: String, as type: T.Type, arguments: [String: Any] = [:]
    ) async throws -> T? {
      try ensureOpen()
      guard let view = webView else { throw ControlledBrowserError.unavailable }
      return try await withCheckedThrowingContinuation { continuation in
        view.callAsyncJavaScript(source, arguments: arguments, in: nil, in: world) { result in
          switch result {
          case .success(let value):
            if value is NSNull {
              continuation.resume(returning: nil)
              return
            }
            guard
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed]),
              let decoded = try? JSONDecoder().decode(T.self, from: data)
            else {
              continuation.resume(throwing: ControlledBrowserError.failed)
              return
            }
            continuation.resume(returning: decoded)
          case .failure: continuation.resume(throwing: ControlledBrowserError.failed)
          }
        }
      }
    }

    private struct PageObservation: Decodable, Sendable {
      struct Link: Decodable, Sendable {
        let text: String
        let href: String
        let truncated: Bool
      }
      let title: String
      let titleTruncated: Bool
      let text: String
      let textTruncated: Bool
      let links: [Link]
    }

    private func snapshot() async throws -> BrowserPage {
      guard login != nil, let view = webView,
        let object = try await script(BrowserScripts.page, as: PageObservation.self)
      else { throw ControlledBrowserError.unsupportedForm }
      try protectCookies(await view.configuration.websiteDataStore.httpCookieStore.allCookies())
      let title = object.title
      let text = object.text
      let rawLinks = object.links
      try ensureOpen()
      links.removeAll()
      var resultLinks: [BrowserPage.Link] = []
      for link in rawLinks {
        let href = link.href
        let label = link.text
        guard !label.isEmpty, let url = URL(string: href),
          BrowserPolicy.permits(url, origin: origin),
          !BrowserPolicy.containsSecret(href, values: protectedValues)
        else { continue }
        let id = UUID()
        links[id] = url
        resultLinks.append(
          .init(
            id: id,
            text: String(
              BrowserPolicy.redact(label, values: protectedValues, captureWasCut: link.truncated)
                .prefix(200))))
      }
      return BrowserPage(
        sessionID: id, status: "pageReady", origin: origin,
        title: String(
          BrowserPolicy.redact(title, values: protectedValues, captureWasCut: object.titleTruncated)
            .prefix(200)),
        text: String(
          BrowserPolicy.redact(text, values: protectedValues, captureWasCut: object.textTruncated)
            .prefix(16000)), links: resultLinks)
    }

    private func protectCookies(_ cookies: [HTTPCookie]) throws {
      let values = Set(protectedValues + cookies.map(\.value).filter { !$0.isEmpty })
      guard values.count <= 512, values.reduce(0, { $0 + $1.utf8.count }) <= 256 * 1024 else {
        throw ControlledBrowserError.failed
      }
      protectedValues = Array(values)
    }

    public func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      guard webView === self.webView else {
        decisionHandler(.cancel)
        return
      }
      guard navigationAction.targetFrame?.isMainFrame == true else {
        decisionHandler(.cancel)
        return
      }
      let request = navigationAction.request
      let method = request.httpMethod ?? "GET"
      guard navigationWaiter != nil, let url = request.url,
        BrowserPolicy.permits(url, origin: origin),
        method == "GET" || (method == "POST" && allowedPost == url),
        !BrowserPolicy.containsSecret(url.absoluteString, values: protectedValues)
      else {
        decisionHandler(.cancel)
        finishNavigation(.failure(ControlledBrowserError.failed))
        return
      }
      decisionHandler(.allow)
    }

    public func webView(
      _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
      guard webView === self.webView, navigationResponse.isForMainFrame,
        let response = navigationResponse.response as? HTTPURLResponse,
        (200..<300).contains(response.statusCode), response.mimeType == "text/html",
        let url = response.url, BrowserPolicy.permits(url, origin: origin),
        navigationResponse.canShowMIMEType
      else {
        decisionHandler(.cancel)
        finishNavigation(.failure(ControlledBrowserError.failed))
        return
      }
      decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard webView === self.webView else { return }
      finishNavigation(.success(()))
    }

    public func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
      guard webView === self.webView else { return }
      finishNavigation(.failure(ControlledBrowserError.failed))
    }

    public func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      self.webView(webView, didFail: navigation, withError: error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      if webView === self.webView { close() }
    }

    public func webView(
      _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
      completionHandler:
        @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
      completionHandler(
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    public func webView(
      _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? { nil }
  }
#endif
