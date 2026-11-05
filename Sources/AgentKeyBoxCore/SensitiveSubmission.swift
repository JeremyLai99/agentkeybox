import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct SensitiveSubmissionRequest: Codable, Hashable, Sendable {
  public enum Encoding: String, Codable, Sendable { case form, json }
  public var fields: [String: String]
  public var encoding: Encoding

  public init(fields: [String: String], encoding: Encoding = .form) {
    self.fields = fields
    self.encoding = encoding
  }
}

/// Only these fixed outcomes cross the broker. No response text, headers, or URLs are returned.
public enum SensitiveSubmissionOutcome: String, Codable, Sendable {
  case received, rejected, redirectBlocked, unknown
}

public enum SensitiveSubmissionPolicy {
  public static let cardFields = [
    "{{card.number}}", "{{card.cardholder}}", "{{card.expiration_month}}",
    "{{card.expiration_year}}",
  ]
  public static let recoveryField = "{{recovery.code}}"

  /// The user configures an exact endpoint in the native editor. Agents cannot override it.
  public static func destination(_ raw: String?) throws -> URL {
    guard let raw, raw.utf8.count <= 2048,
      let components = URLComponents(string: raw), components.scheme == "https",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      !raw.contains("{"), !raw.contains("}"),
      !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
      let url = components.url
    else { throw SensitiveDataError.invalidDestination }
    return url
  }

  public static func validate(
    _ submission: SensitiveSubmissionRequest, credential: CredentialMetadata
  ) throws -> URL {
    guard credential.kind == .creditCard || credential.kind == .recoveryCodes else {
      throw SensitiveDataError.controlledUseRequired
    }
    let url = try destination(credential.submissionURL)
    let placeholders = credential.kind == .creditCard ? cardFields : [recoveryField]
    let names = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.[]")
    guard !submission.fields.isEmpty, submission.fields.count <= 40,
      submission.fields.allSatisfy({ key, value in
        !key.isEmpty && key.count <= 100 && key.allSatisfy { names.contains($0) }
          && value.utf8.count <= 4096
          && (!value.contains("{{") && !value.contains("}}") || placeholders.contains(value))
      }),
      submission.fields.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 32 * 1024,
      submission.fields.values.contains(where: { placeholders.contains($0) })
    else { throw SensitiveDataError.invalidFields }
    if credential.kind == .recoveryCodes,
      submission.fields.values.filter({ $0 == recoveryField }).count != 1
    {
      throw SensitiveDataError.invalidFields
    }
    return url
  }

  /// Called inside the app after approval. `payload` changes must be persisted before sending.
  public static func prepare(
    _ submission: SensitiveSubmissionRequest, credential: CredentialMetadata,
    payload: inout SensitivePayload
  ) throws -> URLRequest {
    let url = try validate(submission, credential: credential)
    guard payload.kind == credential.kind else { throw SensitiveDataError.invalidPayload }
    var replacements: [String: String] = [:]
    if let card = payload.card {
      replacements = [
        "{{card.number}}": card.number, "{{card.cardholder}}": card.cardholder,
        "{{card.expiration_month}}": String(format: "%02d", card.expirationMonth),
        "{{card.expiration_year}}": String(card.expirationYear),
      ]
    } else if var codes = payload.recoveryCodes {
      replacements[recoveryField] = try codes.reserveNext()
      payload.recoveryCodes = codes
    } else {
      throw SensitiveDataError.invalidPayload
    }
    let fields = submission.fields.mapValues { replacements[$0] ?? $0 }
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    switch submission.encoding {
    case .json:
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    case .form:
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
      let body = fields.sorted { $0.key < $1.key }.map { key, value in
        "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
      }.joined(separator: "&")
      request.httpBody = Data(body.utf8)
    }
    return request
  }
}

/// Dedicated response-free transport. No shared cookies, credentials, cache, redirects, or body.
/// It intentionally reports receipt, not payment/login success, and never retries in app code.
final class SensitiveSubmissionTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<SensitiveSubmissionOutcome, Never>?
  private var outcome: SensitiveSubmissionOutcome = .unknown
  #if DEBUG && os(macOS)
    private var submissionFixture: DevelopmentSubmissionFixture?

    static func send(_ request: URLRequest, fixture: DevelopmentSubmissionFixture) async
      -> SensitiveSubmissionOutcome
    {
      guard fixture.accepts(request) else { return .unknown }
      let transport = SensitiveSubmissionTransport()
      transport.submissionFixture = fixture
      return await send(request, configuration: .ephemeral, transport: transport)
    }
  #endif

  static func send(
    _ request: URLRequest, configuration: URLSessionConfiguration = .ephemeral
  ) async -> SensitiveSubmissionOutcome {
    await send(request, configuration: configuration, transport: SensitiveSubmissionTransport())
  }

  private static func send(
    _ request: URLRequest, configuration: URLSessionConfiguration,
    transport: SensitiveSubmissionTransport
  ) async -> SensitiveSubmissionOutcome {
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 30
    let session = URLSession(configuration: configuration, delegate: transport, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    return await withCheckedContinuation { continuation in
      transport.lock.withLock { transport.continuation = continuation }
      session.dataTask(with: request).resume()
    }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if let response = response as? HTTPURLResponse {
      lock.withLock {
        switch response.statusCode {
        case 200..<300: outcome = .received
        case 300..<400: outcome = .redirectBlocked
        case 400..<600: outcome = .rejected
        default: outcome = .unknown
        }
      }
    }
    // Stop before downloading any response body, including reflected/encoded secrets.
    completionHandler(.cancel)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    lock.withLock { outcome = .redirectBlocked }
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    #if DEBUG && os(macOS)
      if let submissionFixture { return submissionFixture.disposition(challenge) }
    #endif
    // Retain normal TLS certificate validation. Never use a saved HTTP login credential.
    #if canImport(Security)
      if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
        return (.performDefaultHandling, nil)
      }
    #endif
    return (.cancelAuthenticationChallenge, nil)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let pair = lock.withLock {
      () -> (CheckedContinuation<SensitiveSubmissionOutcome, Never>?, SensitiveSubmissionOutcome) in
      defer { continuation = nil }
      return (continuation, outcome)
    }
    pair.0?.resume(returning: pair.1)
  }
}

public enum SensitiveSubmissionExecutor {
  /// The app holds its approval slot across this call. Persistence completes synchronously on
  /// the main actor before networking; a failed save never calls the transport.
  @MainActor
  public static func execute(
    _ submission: SensitiveSubmissionRequest, credential: CredentialMetadata,
    payload: SensitivePayload, persistReservation: (Data) throws -> Void
  ) async throws -> SensitiveSubmissionOutcome {
    #if DEBUG && os(macOS)
      if let profile = DevelopmentProfile.current,
        let fixture = try DevelopmentSubmissionFixture.load(profile: profile)
      {
        try fixture.validate(credential)
        return try await execute(
          submission, credential: credential, payload: payload,
          persistReservation: persistReservation,
          send: { await SensitiveSubmissionTransport.send($0, fixture: fixture) })
      }
    #endif
    return try await execute(
      submission, credential: credential, payload: payload,
      persistReservation: persistReservation, send: { await SensitiveSubmissionTransport.send($0) })
  }

  @MainActor
  static func execute(
    _ submission: SensitiveSubmissionRequest, credential: CredentialMetadata,
    payload: SensitivePayload, persistReservation: (Data) throws -> Void,
    send: (URLRequest) async -> SensitiveSubmissionOutcome
  ) async throws -> SensitiveSubmissionOutcome {
    var payload = try SensitivePayload.decode(payload.encoded(), kind: credential.kind)
    guard credential.payloadRevision == payload.revision else {
      throw SensitiveDataError.invalidPayload
    }
    let request = try SensitiveSubmissionPolicy.prepare(
      submission, credential: credential, payload: &payload)
    if credential.kind == .recoveryCodes { try persistReservation(payload.encoded()) }
    return await send(request)
  }
}
