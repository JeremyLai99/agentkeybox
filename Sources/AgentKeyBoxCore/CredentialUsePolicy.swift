import Foundation

/// Recheck after a suspended secret read, before any secret is used or returned.
public enum CredentialUsePolicy {
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
