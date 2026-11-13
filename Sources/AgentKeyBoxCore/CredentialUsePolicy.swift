import Foundation

/// Recheck after a suspended secret read, before any secret is used or returned.
public enum CredentialUsePolicy {
  public enum FailureDisposition: Equatable, Sendable {
    case credentialChanged
    case operationFailed
  }

  /// Once execution starts, failure may mean an unknown remote outcome. Asking for approval
  /// again would incorrectly imply nothing happened and could encourage a duplicate POST.
  public static func failureDisposition(
    executionStarted: Bool, credentialIsCurrent: Bool
  ) -> FailureDisposition {
    !executionStarted && !credentialIsCurrent ? .credentialChanged : .operationFailed
  }

  public static func isCurrent(
    approved: [CredentialMetadata], current: [CredentialMetadata], projects: [Project],
    projectPath: String, isRevoked: Bool
  ) -> Bool {
    !isRevoked
      && approved.allSatisfy { expected in
        current.first(where: { $0.id == expected.id }) == expected
          && ProjectScopeResolver.isVisible(expected, projects: projects, requestPath: projectPath)
      }
  }
}
