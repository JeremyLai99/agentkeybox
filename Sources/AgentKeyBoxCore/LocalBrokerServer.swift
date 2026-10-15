import Foundation

#if os(macOS)
  import Darwin

  /// The broker: a Unix-domain socket in the owner-only support directory. Each connection
  /// carries one newline-terminated JSON request and gets one response. Plain BSD sockets (not
  /// Network.framework) so the caller's audit token can be read and its code signature checked.
  public final class LocalBrokerServer: @unchecked Sendable {
    public typealias Handler = @Sendable (BrokerRequest) async -> BrokerResponse

    private let socketURL: URL
    private let expectedAuthToken: String
    private let peerPolicy: BrokerPeerPolicy
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.agentkeybox.broker.server")
    private let replayGuard = BrokerReplayGuard()
    private let maxRequestBytes = 64 * 1024
    private var acceptSource: DispatchSourceRead?

    public init(
      socketURL: URL = BrokerEndpoint.defaultSocketURL,
      expectedAuthToken: String,
      peerPolicy: BrokerPeerPolicy = .forCurrentProcess(),
      handler: @escaping Handler
    ) {
      self.socketURL = socketURL
      self.expectedAuthToken = expectedAuthToken
      self.peerPolicy = peerPolicy
      self.handler = handler
    }

    public func start() throws {
      guard acceptSource == nil else { return }
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

      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw BrokerError.requestFailed("Could not create the broker socket.") }
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let capacity = MemoryLayout.size(ofValue: address.sun_path)
      withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        path.utf8CString.withUnsafeBytes { source in
          buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(capacity)))
        }
      }
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
        close(fd)
        throw BrokerError.requestFailed("Could not start the broker socket.")
      }
      _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      source.setEventHandler { [weak self] in self?.acceptPending(fd) }
      source.setCancelHandler { close(fd) }
      source.resume()
      acceptSource = source
    }

    public func stop() {
      acceptSource?.cancel()
      acceptSource = nil
      try? FileManager.default.removeItem(at: socketURL)
    }

    deinit { acceptSource?.cancel() }

    private func acceptPending(_ listener: Int32) {
      while true {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }  // EAGAIN: nothing more to accept
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // A client that never finishes its request line cannot hold the connection open.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Identify the caller now, while it is certainly still connected.
        let peer: BrokerPeerPolicy.Peer?
        if case .signedBy(let teamID) = peerPolicy {
          peer = BrokerPeerPolicy.peer(ofSocket: client, teamID: teamID)
        } else {
          peer = nil
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
          guard let self, let line = self.readLine(client) else {
            close(client)
            return
          }
          Task {
            let response = await self.response(for: line, peer: peer)
            self.write(response, to: client)
            close(client)
          }
        }
      }
    }

    /// The request line, or nil when the client sent nothing usable. An oversized request is
    /// answered with an error here.
    private func readLine(_ fd: Int32) -> Data? {
      var buffer = Data()
      var chunk = [UInt8](repeating: 0, count: 16 * 1024)
      while true {
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else { return buffer.isEmpty ? nil : buffer }
        buffer.append(contentsOf: chunk[0..<count])
        if let newline = buffer.firstIndex(of: 0x0A) { return Data(buffer[..<newline]) }
        if buffer.count > maxRequestBytes {
          write(
            BrokerResponse(ok: false, error: "Local broker request exceeded the maximum size."),
            to: fd)
          return nil
        }
      }
    }

    private func response(for line: Data, peer: BrokerPeerPolicy.Peer?) async -> BrokerResponse {
      guard let request = try? JSONDecoder().decode(BrokerRequest.self, from: line) else {
        return BrokerResponse(ok: false, error: "Invalid local broker request.")
      }
      guard Self.constantTimeEquals(request.authToken ?? "", expectedAuthToken) else {
        return BrokerResponse(ok: false, error: "Unauthorized local broker request.")
      }
      if let rejection = peerPolicy.rejection(of: peer, for: request.action) {
        return BrokerResponse(ok: false, error: rejection)
      }
      guard await replayGuard.accept(request) else {
        return BrokerResponse(ok: false, error: "Expired or replayed local broker request.")
      }
      return await handler(request)
    }

    private func write(_ response: BrokerResponse, to fd: Int32) {
      guard var encoded = try? JSONEncoder().encode(response) else { return }
      encoded.append(0x0A)
      encoded.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
          if written <= 0 { return }
          offset += written
        }
      }
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
      let left = Array(a.utf8)
      let right = Array(b.utf8)
      var difference = UInt8(left.count == right.count ? 0 : 1)
      for index in 0..<max(left.count, right.count) {
        difference |= (index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0)
      }
      return difference == 0
    }
  }
#else
  public final class LocalBrokerServer: @unchecked Sendable {
    public typealias Handler = @Sendable (BrokerRequest) async -> BrokerResponse
    public init(
      socketURL: URL = BrokerEndpoint.defaultSocketURL,
      expectedAuthToken: String,
      peerPolicy: BrokerPeerPolicy = .unverified,
      handler: @escaping Handler
    ) {}
    public func start() throws { throw BrokerError.unsupportedPlatform }
    public func stop() {}
  }
#endif
