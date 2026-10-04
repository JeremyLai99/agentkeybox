import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The token an agent writes where the credential belongs, e.g. `Authorization: Bearer {{secret}}`.
public let secretPlaceholder = "{{secret}}"

public enum HTTPRequestPolicyError: Error, LocalizedError, Equatable {
  case invalidURL
  case httpsRequired
  case credentialsInURL
  case unsupportedMethod(String)
  case invalidHeaderName(String)
  case forbiddenHeader(String)
  case placeholderMissing
  case placeholderOutsideHeaders
  case hostNotAllowed(host: String, allowed: [String])
  case bodyTooLarge

  public var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "The request URL is invalid."
    case .httpsRequired:
      return "http_request only sends credentials over https."
    case .credentialsInURL:
      return "The request URL must not contain a username or password."
    case .unsupportedMethod(let method):
      return "HTTP method \(method) is not supported."
    case .invalidHeaderName(let name):
      return "Header name \"\(name)\" is invalid."
    case .forbiddenHeader(let name):
      return "Header \"\(name)\" cannot be set by an agent."
    case .placeholderMissing:
      return
        "Put {{secret}} in a header value where the credential belongs, e.g. Authorization: Bearer {{secret}}."
    case .placeholderOutsideHeaders:
      return "{{secret}} is only allowed in header values, not in the URL or body."
    case .hostNotAllowed(let host, let allowed):
      return
        "This credential may only be sent to \(allowed.joined(separator: ", ")), not \(host). Change the credential's allowed hosts in AgentKeyBox if this is intended."
    case .bodyTooLarge:
      return "The request body exceeds AgentKeyBox's 256 KiB limit."
    }
  }
}

/// A request that passed `HTTPRequestPolicy`; the secret has not been inserted yet.
public struct ValidatedHTTPRequest: Hashable, Sendable {
  public var method: String
  public var url: URL
  public var host: String
  public var headers: [String: String]
  public var body: String?
  /// False when the credential has no allowlist; the approval prompt warns about it.
  public var hostRestricted: Bool
}

public enum HTTPRequestPolicy {
  public static let allowedMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
  public static let maxBodyBytes = 256 * 1024
  /// Set by URLSession itself; letting an agent override them could smuggle the request elsewhere.
  static let forbiddenHeaders: Set<String> = [
    "host", "content-length", "transfer-encoding", "connection", "proxy-authorization",
  ]

  public static func validate(
    method rawMethod: String,
    url rawURL: String,
    headers: [String: String],
    body: String?,
    allowedHosts: [String]?
  ) throws -> ValidatedHTTPRequest {
    let method = rawMethod.uppercased()
    guard allowedMethods.contains(method) else {
      throw HTTPRequestPolicyError.unsupportedMethod(rawMethod)
    }
    guard let components = URLComponents(string: rawURL), let url = components.url,
      let host = components.host?.lowercased(), !host.isEmpty
    else {
      throw HTTPRequestPolicyError.invalidURL
    }
    guard components.scheme?.lowercased() == "https" else {
      throw HTTPRequestPolicyError.httpsRequired
    }
    guard components.user == nil, components.password == nil else {
      throw HTTPRequestPolicyError.credentialsInURL
    }
    if rawURL.contains(secretPlaceholder) || (body?.contains(secretPlaceholder) ?? false) {
      throw HTTPRequestPolicyError.placeholderOutsideHeaders
    }
    if let body, body.utf8.count > maxBodyBytes {
      throw HTTPRequestPolicyError.bodyTooLarge
    }

    for name in headers.keys {
      guard isValidHeaderName(name) else { throw HTTPRequestPolicyError.invalidHeaderName(name) }
      guard !forbiddenHeaders.contains(name.lowercased()) else {
        throw HTTPRequestPolicyError.forbiddenHeader(name)
      }
    }
    guard headers.values.contains(where: { $0.contains(secretPlaceholder) }) else {
      throw HTTPRequestPolicyError.placeholderMissing
    }

    let restriction = (allowedHosts ?? []).filter { !$0.isEmpty }
    if !restriction.isEmpty, !restriction.contains(where: { hostMatches(host, pattern: $0) }) {
      throw HTTPRequestPolicyError.hostNotAllowed(host: host, allowed: restriction)
    }

    return ValidatedHTTPRequest(
      method: method, url: url, host: host, headers: headers, body: body,
      hostRestricted: !restriction.isEmpty)
  }

  /// `*.supabase.co` matches `abc.supabase.co` but not `supabase.co` or `evil-supabase.co`.
  public static func hostMatches(_ host: String, pattern rawPattern: String) -> Bool {
    let host = host.lowercased()
    let pattern = rawPattern.lowercased()
    if pattern.hasPrefix("*.") {
      return host.hasSuffix(String(pattern.dropFirst(1))) && host.count > pattern.count - 1
    }
    return host == pattern
  }

  static func isValidHeaderName(_ name: String) -> Bool {
    let allowed = Set(
      "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    return !name.isEmpty && name.allSatisfy { allowed.contains($0) }
  }
}

public struct HTTPExecutionResult: Codable, Hashable, Sendable {
  public var statusCode: Int
  public var contentType: String?
  public var body: String
  public var bodyTruncated: Bool

  public init(statusCode: Int, contentType: String?, body: String, bodyTruncated: Bool) {
    self.statusCode = statusCode
    self.contentType = contentType
    self.body = body
    self.bodyTruncated = bodyTruncated
  }
}

public enum HTTPRequestExecutorError: Error, LocalizedError, Equatable {
  case secretNotUTF8
  case transport(String)
  case timedOut

  public var errorDescription: String? {
    switch self {
    case .secretNotUTF8:
      return "This credential is not text and cannot be placed in an HTTP header."
    case .transport(let message):
      return "The HTTP request failed: \(message)"
    case .timedOut:
      return "The HTTP request exceeded AgentKeyBox's timeout."
    }
  }
}

public enum HTTPRequestExecutor {
  public static func execute(
    _ request: ValidatedHTTPRequest,
    secretData: Data,
    timeoutSeconds: TimeInterval = 30,
    maxResponseBytes: Int = 128 * 1024
  ) async throws -> HTTPExecutionResult {
    guard let secret = String(data: secretData, encoding: .utf8) else {
      throw HTTPRequestExecutorError.secretNotUTF8
    }

    var urlRequest = URLRequest(url: request.url, timeoutInterval: timeoutSeconds)
    urlRequest.httpMethod = request.method
    urlRequest.httpShouldHandleCookies = false
    for (name, value) in request.headers {
      urlRequest.setValue(
        value.replacingOccurrences(of: secretPlaceholder, with: secret), forHTTPHeaderField: name)
    }
    if let body = request.body {
      urlRequest.httpBody = Data(body.utf8)
    }

    // Fetch a margin beyond the visible limit and redact before truncating, so a secret that
    // straddles the cut-off is still recognized and never leaks a prefix.
    let fetch = try await CappedFetch.run(
      urlRequest, maxBytes: maxResponseBytes + SecretRedactor.margin(for: secretData))
    let (body, truncated) = SecretRedactor.redactThenTruncate(
      fetch.data, secretData: secretData, maxBytes: maxResponseBytes)
    return HTTPExecutionResult(
      statusCode: fetch.statusCode, contentType: fetch.contentType, body: body,
      bodyTruncated: truncated || fetch.truncated)
  }
}

/// Streams a response, keeping at most `maxBytes` plus a small redaction margin, and refuses
/// redirects so the credential header is never replayed to a different URL.
private final class CappedFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  struct Output {
    var statusCode: Int
    var contentType: String?
    var data: Data
    var truncated: Bool
  }

  private let maxBytes: Int
  private let lock = NSLock()
  private var data = Data()
  private var truncated = false
  private var response: HTTPURLResponse?
  private var continuation: CheckedContinuation<Output, Error>?

  private init(maxBytes: Int) {
    self.maxBytes = maxBytes
  }

  static func run(_ request: URLRequest, maxBytes: Int) async throws -> Output {
    let fetch = CappedFetch(maxBytes: maxBytes)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = request.timeoutInterval
    configuration.timeoutIntervalForResource = request.timeoutInterval
    let session = URLSession(configuration: configuration, delegate: fetch, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    return try await withCheckedThrowingContinuation { continuation in
      fetch.lock.withLock { fetch.continuation = continuation }
      session.dataTask(with: request).resume()
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    lock.withLock { self.response = response as? HTTPURLResponse }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    let full = lock.withLock { () -> Bool in
      let room = maxBytes - data.count
      if chunk.count > room {
        data.append(chunk.prefix(max(room, 0)))
        truncated = true
        return true
      }
      data.append(chunk)
      return false
    }
    if full { dataTask.cancel() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let (continuation, output): (CheckedContinuation<Output, Error>?, Output?) = lock.withLock {
      defer { self.continuation = nil }
      guard let response else { return (self.continuation, nil) }
      return (
        self.continuation,
        Output(
          statusCode: response.statusCode,
          contentType: response.value(forHTTPHeaderField: "Content-Type"),
          data: data, truncated: truncated)
      )
    }
    if let output, error == nil || truncated {
      continuation?.resume(returning: output)
    } else if let error = error as? URLError, error.code == .timedOut {
      continuation?.resume(throwing: HTTPRequestExecutorError.timedOut)
    } else {
      continuation?.resume(
        throwing: HTTPRequestExecutorError.transport(
          error?.localizedDescription ?? "No response was received."))
    }
  }
}
