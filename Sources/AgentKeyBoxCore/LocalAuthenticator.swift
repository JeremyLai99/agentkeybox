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

  public final class LocalAuthenticator: @unchecked Sendable {
    public init() {}

    /// Returns true when biometric/device-owner authentication was available and succeeded.
    /// Returns false when the Mac has no usable local authentication policy configured.
    public func authenticateIfAvailable(reason: String) async throws -> Bool {
      let context = LAContext()
      context.localizedCancelTitle = "Cancel"
      var error: NSError?
      guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
      else {
        return false
      }
      do {
        let success = try await context.evaluatePolicy(
          .deviceOwnerAuthenticationWithBiometrics,
          localizedReason: reason
        )
        if !success {
          throw LocalAuthenticationError.failed("Local authentication was not completed.")
        }
        return true
      } catch {
        throw LocalAuthenticationError.failed(error.localizedDescription)
      }
    }
  }
#else
  public final class LocalAuthenticator: @unchecked Sendable {
    public init() {}
    public func authenticateIfAvailable(reason: String) async throws -> Bool { false }
  }
#endif
