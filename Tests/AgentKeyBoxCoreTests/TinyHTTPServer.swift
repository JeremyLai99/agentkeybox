#if os(macOS)
  import Foundation
  import Network

  /// Minimal loopback HTTP/1.1 server for executor tests.
  /// `/echo` returns the request's Authorization header; `/redirect` answers 302 to `/echo`.
  final class TinyHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.agentkeybox.tests.http")
    private let lock = NSLock()
    private var paths: [String] = []
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    var requestedPaths: [String] { lock.withLock { paths } }

    init() throws {
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
      listener = try NWListener(using: parameters)
      let ready = DispatchSemaphore(value: 0)
      listener.stateUpdateHandler = { state in
        if case .ready = state { ready.signal() }
      }
      listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
      listener.start(queue: queue)
      _ = ready.wait(timeout: .now() + 5)
    }

    func stop() {
      listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
      connection.start(queue: queue)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
        [weak self] data, _, _, _ in
        guard let self, let data, let request = String(data: data, encoding: .utf8) else {
          connection.cancel()
          return
        }
        let lines = request.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let authorization =
          lines.first { $0.lowercased().hasPrefix("authorization:") }?
          .dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) ?? ""
        self.lock.withLock { self.paths.append(path) }

        let response: String
        if path == "/redirect" {
          response =
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(self.port)/echo\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        } else {
          let body = "you sent: \(authorization)"
          response =
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        }
        connection.send(
          content: Data(response.utf8),
          completion: .contentProcessed { _ in connection.cancel() })
      }
    }
  }
#endif
