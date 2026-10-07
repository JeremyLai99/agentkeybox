import Foundation

public enum LocalAuthenticationError: Error, LocalizedError {
  case failed(String)

  public var errorDescription: String? {
    switch self {
    case .failed(let message): return message
    }
  }
}

#if os(macOS)
  import LocalAuthentication

  /// Proof that the user just authenticated. Passing it to `KeychainSecretStore.read` lets the
  /// keychain reuse that authentication instead of prompting a second time.
  public final class AuthenticationGrant: @unchecked Sendable {
    let context: LAContext

    init(context: LAContext) {
      self.context = context
    }

    /// Ends the authentication so it can no longer unlock keychain items.
    public func invalidate() {
      context.invalidate()
    }
  }

  public final class LocalAuthenticator: @unchecked Sendable {
    private let lock = NSLock()
    private var activeContext: LAContext?

    public init() {}

    /// Returns a grant when device-owner authentication was available and succeeded.
    /// Returns nil only when the Mac has no local authentication configured at all.
    ///
    /// Uses `.deviceOwnerAuthentication` (Touch ID, falling back to the login password) rather
    /// than biometrics only: the biometrics-only policy reports "not enrolled" when no fingerprint
    /// is registered, which previously skipped confirmation entirely and approved on one click.
    public func authenticate(reason: String) async throws -> AuthenticationGrant? {
      let context = LAContext()
      context.localizedCancelTitle = "Cancel"
      var error: NSError?
      guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
        return nil
      }
      lock.withLock { activeContext = context }
      defer {
        lock.withLock {
          if activeContext === context { activeContext = nil }
        }
      }
      do {
        let success = try await context.evaluatePolicy(
          .deviceOwnerAuthentication,
          localizedReason: reason
        )
        if !success {
          throw LocalAuthenticationError.failed("Local authentication was not completed.")
        }
        return AuthenticationGrant(context: context)
      } catch {
        throw LocalAuthenticationError.failed(error.localizedDescription)
      }
    }

    /// Dismisses a Touch ID / password prompt that is still on screen, e.g. after the approval
    /// timed out. The pending `authenticate` call then throws.
    public func cancelPendingAuthentication() {
      let context = lock.withLock {
        defer { activeContext = nil }
        return activeContext
      }
      context?.invalidate()
    }
  }
#else
  public final class AuthenticationGrant: @unchecked Sendable {
    public func invalidate() {}
  }

  public final class LocalAuthenticator: @unchecked Sendable {
    public init() {}
    public func authenticate(reason: String) async throws -> AuthenticationGrant? { nil }
    public func cancelPendingAuthentication() {}
  }
#endif
