import Foundation

#if os(macOS)
  import Network

  public final class LocalBrokerServer: @unchecked Sendable {
    public typealias Handler = @Sendable (BrokerRequest) async -> BrokerResponse

    private let socketURL: URL
    private let expectedAuthToken: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.agentkeybox.broker.server")
    private let replayGuard = BrokerReplayGuard()
    private let maxRequestBytes = 64 * 1024
    private var listener: NWListener?

    public init(
      socketURL: URL = BrokerEndpoint.defaultSocketURL,
      expectedAuthToken: String,
      handler: @escaping Handler
    ) {
      self.socketURL = socketURL
      self.expectedAuthToken = expectedAuthToken
      self.handler = handler
    }

    public func start() throws {
      guard listener == nil else { return }
      let path = socketURL.path
      guard path.utf8.count <= BrokerEndpoint.maxSocketPathBytes else {
        throw BrokerError.socketPathTooLong
      }

      // The owner-only directory is the access boundary: other users cannot connect to,
      // replace, or pre-create the socket inside it.
      let directory = socketURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
      // Remove a stale socket left behind by a previous crash; bind fails otherwise.
      try? FileManager.default.removeItem(atPath: path)

      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .unix(path: path)
      let listener = try NWListener(using: parameters)
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection)
      }
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        case .failed(let error):
          FileHandle.standardError.write(Data("AgentKeyBox broker failed: \(error)\n".utf8))
        default:
          break
        }
      }
      listener.start(queue: queue)
      self.listener = listener
    }

    public func stop() {
      listener?.cancel()
      listener = nil
      try? FileManager.default.removeItem(at: socketURL)
    }

    deinit { listener?.cancel() }

    private func accept(_ connection: NWConnection) {
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
            let response = await self.response(for: line)
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

    private func response(for line: Data) async -> BrokerResponse {
      guard let request = try? JSONDecoder().decode(BrokerRequest.self, from: line) else {
        return BrokerResponse(ok: false, error: "Invalid local broker request.")
      }
      guard request.authToken == expectedAuthToken else {
        return BrokerResponse(ok: false, error: "Unauthorized local broker request.")
      }
      guard await replayGuard.accept(request) else {
        return BrokerResponse(ok: false, error: "Expired or replayed local broker request.")
      }
      return await handler(request)
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
      socketURL: URL = BrokerEndpoint.defaultSocketURL,
      expectedAuthToken: String,
      handler: @escaping Handler
    ) {}
    public func start() throws { throw BrokerError.unsupportedPlatform }
    public func stop() {}
  }
#endif
