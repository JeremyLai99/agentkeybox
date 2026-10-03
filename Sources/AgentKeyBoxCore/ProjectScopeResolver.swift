import Foundation

public enum ProjectScopeResolver {
  public static func normalize(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }

  public static func contains(projectRoot: String, requestPath: String) -> Bool {
    let root = normalize(projectRoot)
    let request = normalize(requestPath)
    guard request != root else { return true }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return request.hasPrefix(prefix)
  }

  public static func isVisible(
    _ credential: CredentialMetadata,
    projects: [Project],
    requestPath: String
  ) -> Bool {
    guard let projectID = credential.projectID else { return true }
    guard let project = projects.first(where: { $0.id == projectID }) else { return false }
    return contains(projectRoot: project.rootPath, requestPath: requestPath)
  }
}
