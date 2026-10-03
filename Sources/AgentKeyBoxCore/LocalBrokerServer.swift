import Foundation

#if os(macOS)
  import Network

  public final class LocalBrokerServer: @unchecked Sendable {
    public typealias Handler = @Sendable (BrokerRequest) async -> BrokerResponse

    private let port: UInt16
    private let expectedAuthToken: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.agentkeybox.broker.server")
    private let replayGuard = BrokerReplayGuard()
    private let maxRequestBytes = 64 * 1024
    private var listener: NWListener?

    public init(
      port: UInt16 = LocalBrokerClient.defaultPort,
      expectedAuthToken: String,
      handler: @escaping Handler
    ) {
      self.port = port
      self.expectedAuthToken = expectedAuthToken
      self.handler = handler
    }

    public func start() throws {
      guard listener == nil else { return }
      let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection)
      }
      listener.stateUpdateHandler = { state in
        if case .failed(let error) = state {
          FileHandle.standardError.write(Data("AgentKeyBox broker failed: \(error)\n".utf8))
        }
      }
      listener.start(queue: queue)
      self.listener = listener
    }

    public func stop() {
      listener?.cancel()
      listener = nil
    }

    deinit { listener?.cancel() }

    private func accept(_ connection: NWConnection) {
      let endpointText = String(describing: connection.endpoint)
      guard
        endpointText.contains("127.0.0.1") || endpointText.contains("::1")
          || endpointText.contains("localhost")
      else {
        connection.cancel()
        return
      }
      connection.start(queue: queue)
      receiveLine(connection: connection)
    }

    private func receiveLine(connection: NWConnection, buffer: Data = Data()) {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
        [weak self] data, _, isComplete, error in
        guard let self else {
          connection.cancel()
          return
        }
        if error != nil {
          connection.cancel()
          return
        }

        var next = buffer
        if let data { next.append(data) }
        if next.count > self.maxRequestBytes {
          Task {
            try? await self.send(
              BrokerResponse(ok: false, error: "Local broker request exceeded the maximum size."),
              on: connection
            )
          }
          return
        }

        if let newline = next.firstIndex(of: 0x0A) {
          let line = Data(next[..<newline])
          Task {
            let response: BrokerResponse
            do {
              let request = try JSONDecoder().decode(BrokerRequest.self, from: line)
              guard request.authToken == self.expectedAuthToken else {
                response = BrokerResponse(ok: false, error: "Unauthorized local broker request.")
                try await self.send(response, on: connection)
                return
              }
              guard await self.replayGuard.accept(request) else {
                response = BrokerResponse(
                  ok: false, error: "Expired or replayed local broker request.")
                try await self.send(response, on: connection)
                return
              }
              response = await self.handler(request)
            } catch {
              response = BrokerResponse(ok: false, error: "Invalid local broker request.")
            }
            try? await self.send(response, on: connection)
          }
          return
        }
        if isComplete {
          connection.cancel()
          return
        }
        self.receiveLine(connection: connection, buffer: next)
      }
    }

    private func send(_ response: BrokerResponse, on connection: NWConnection) async throws {
      var encoded = try JSONEncoder().encode(response)
      encoded.append(0x0A)
      await withCheckedContinuation { continuation in
        connection.send(
          content: encoded,
          completion: .contentProcessed { _ in
            connection.cancel()
            continuation.resume()
          })
      }
    }
  }
#else
  public final class LocalBrokerServer: @unchecked Sendable {
    public typealias Handler = @Sendable (BrokerRequest) async -> BrokerResponse
    public init(
      port: UInt16 = LocalBrokerClient.defaultPort,
      expectedAuthToken: String,
      handler: @escaping Handler
    ) {}
    public func start() throws { throw BrokerError.unsupportedPlatform }
    public func stop() {}
  }
#endif
