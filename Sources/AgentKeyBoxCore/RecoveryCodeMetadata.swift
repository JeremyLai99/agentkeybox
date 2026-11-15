import Foundation

/// Issued codes have an unverified remote outcome and count as needing review.
public struct RecoveryCodeCounts: Codable, Hashable, Sendable {
  public let available: Int
  public let used: Int
  public let needsReview: Int

  public init(codes: RecoveryCodeSet) {
    available = codes.entries.filter { $0.status == .available }.count
    used = codes.entries.filter { $0.status == .used }.count
    needsReview = codes.entries.filter { $0.status == .issued || $0.status == .needsReview }.count
  }

  private init(available: Int, used: Int, needsReview: Int) {
    self.available = available
    self.used = used
    self.needsReview = needsReview
  }

  /// Metadata-first edits cannot advertise newly available codes before the secret commit.
  public func staged(over previous: RecoveryCodeCounts?) -> Self {
    let safeAvailable = min(previous?.available ?? 0, available)
    return Self(
      available: safeAvailable, used: used, needsReview: needsReview + available - safeAvailable)
  }

  public var listing: String {
    "codes=available:\(available),used:\(used),needs_review:\(needsReview)"
  }
}

public enum RecoveryCodeMetadataCommit {
  /// Synchronous, serialized with the caller's metadata operations. `saveSecret` has the
  /// RecoverableSecretReplacement contract: it throws only before its pending-slot commit.
  public static func reserve(
    _ data: Data, credential: CredentialMetadata,
    saveMetadata: (CredentialMetadata) throws -> Void,
    saveSecret: (Data) throws -> Void
  ) throws {
    let payload = try SensitivePayload.decode(data, kind: .recoveryCodes)
    guard credential.kind == .recoveryCodes, credential.recoveryCodePendingRevision == nil,
      payload.revision != credential.payloadRevision, let codes = payload.recoveryCodes
    else { throw SensitiveDataError.invalidPayload }
    var staged = credential
    staged.recoveryCodeCounts = RecoveryCodeCounts(codes: codes)
    staged.recoveryCodePendingRevision = payload.revision
    staged.updatedAt = Date()
    // A crash here can only under-report availability. No secret has been released.
    try saveMetadata(staged)
    do {
      try saveSecret(data)
    } catch {
      // Failed before the secret commit. A failed rollback keeps conservative counts.
      try? saveMetadata(credential)
      throw SensitiveDataError.invalidPayload
    }
    // Never roll back after secret commit: the pending Keychain slot is authoritative.
    staged.payloadRevision = payload.revision
    staged.recoveryCodePendingRevision = nil
    try saveMetadata(staged)
  }

  /// Native authenticated review only. Accept the current revision or an explicitly staged
  /// reservation, never an arbitrary mismatched payload. Also upgrades legacy unknown counts.
  public static func reconciled(
    _ credential: CredentialMetadata, payload: SensitivePayload
  ) throws -> CredentialMetadata {
    guard credential.kind == .recoveryCodes, let codes = payload.recoveryCodes,
      payload.revision == credential.payloadRevision
        || payload.revision == credential.recoveryCodePendingRevision
    else { throw SensitiveDataError.invalidPayload }
    var current = credential
    current.payloadRevision = payload.revision
    current.recoveryCodePendingRevision = nil
    current.recoveryCodeCounts = RecoveryCodeCounts(codes: codes)
    if current != credential { current.updatedAt = Date() }
    return current
  }
}
