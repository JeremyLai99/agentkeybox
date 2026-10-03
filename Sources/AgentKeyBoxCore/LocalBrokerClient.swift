import Foundation

#if os(macOS)
  import Network

  private final class BrokerCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !completed else { return false }
      completed = true
      return true
    }
  }

  public final class LocalBrokerClient: @unchecked Sendable {
    public static let defaultPort: UInt16 = 49321

    private let port: UInt16
    private let tokenStore: BrokerTokenStore
    private let timeoutSeconds: TimeInterval

    public init(
      port: UInt16 = LocalBrokerClient.defaultPort,
      tokenStore: BrokerTokenStore = BrokerTokenStore(),
      timeoutSeconds: TimeInterval = 135
    ) {
      self.port = port
      self.tokenStore = tokenStore
      self.timeoutSeconds = timeoutSeconds
    }

    public func send(_ originalRequest: BrokerRequest) async throws -> BrokerResponse {
      var request = originalRequest
      do {
        request.authToken = try tokenStore.load()
      } catch {
        throw BrokerError.brokerAuthenticationUnavailable
      }

      let encoder = JSONEncoder()
      var payload = try encoder.encode(request)
      payload.append(0x0A)

      let connection = NWConnection(
        host: NWEndpoint.Host("127.0.0.1"),
        port: NWEndpoint.Port(rawValue: port)!,
        using: .tcp
      )

      return try await withCheckedThrowingContinuation { continuation in
        let queue = DispatchQueue(label: "dev.agentkeybox.broker.client")
        let completionBox = BrokerCompletionBox()
        let finish: @Sendable (Result<BrokerResponse, Error>) -> Void = { result in
          guard completionBox.claim() else { return }
          connection.cancel()
          continuation.resume(with: result)
        }

        queue.asyncAfter(deadline: .now() + timeoutSeconds) {
          finish(.failure(BrokerError.requestTimedOut))
        }

        connection.stateUpdateHandler = { state in
          switch state {
          case .ready:
            connection.send(
              content: payload,
              completion: .contentProcessed { error in
                if let error {
                  finish(.failure(error))
                  return
                }
                Self.receiveLine(connection: connection) { result in
                  switch result {
                  case .success(let data):
                    do {
                      let response = try JSONDecoder().decode(BrokerResponse.self, from: data)
                      if response.ok {
                        finish(.success(response))
                      } else {
                        finish(
                          .failure(BrokerError.requestFailed(response.error ?? "Request denied.")))
                      }
                    } catch {
                      finish(.failure(BrokerError.invalidResponse))
                    }
                  case .failure(let error):
                    finish(.failure(error))
                  }
                }
              })
          case .failed:
            finish(.failure(BrokerError.appNotRunning))
          case .cancelled:
            break
          default:
            break
          }
        }
        connection.start(queue: queue)
      }
    }

    private static func receiveLine(
      connection: NWConnection,
      buffer: Data = Data(),
      completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
        data, _, isComplete, error in
        if let error {
          completion(.failure(error))
          return
        }
        var next = buffer
        if let data { next.append(data) }
        if next.count > 1024 * 1024 {
          completion(.failure(BrokerError.invalidResponse))
          return
        }
        if let newline = next.firstIndex(of: 0x0A) {
          completion(.success(Data(next[..<newline])))
          return
        }
        if isComplete {
          completion(next.isEmpty ? .failure(BrokerError.invalidResponse) : .success(next))
          return
        }
        receiveLine(connection: connection, buffer: next, completion: completion)
      }
    }
  }
#else
  public final class LocalBrokerClient: @unchecked Sendable {
    public static let defaultPort: UInt16 = 49321
    public init(
      port: UInt16 = LocalBrokerClient.defaultPort,
      tokenStore: BrokerTokenStore = BrokerTokenStore(),
      timeoutSeconds: TimeInterval = 135
    ) {}
    public func send(_ request: BrokerRequest) async throws -> BrokerResponse {
      throw BrokerError.unsupportedPlatform
    }
  }
#endif
