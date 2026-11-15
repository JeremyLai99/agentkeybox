import XCTest

@testable import AgentKeyBoxCore

final class RecoveryCodeMetadataTests: XCTestCase {
  private func fixture() throws -> (CredentialMetadata, SensitivePayload) {
    let payload = SensitivePayload(
      recoveryCodes: try RecoveryCodeSet(text: "fixture-code-one\nfixture-code-two"))
    return (
      CredentialMetadata(
        label: "Codes", service: "Fixture", kind: .recoveryCodes,
        linkedLoginID: UUID(),
        recoveryCodeCounts: payload.recoveryCodes.map(RecoveryCodeCounts.init(codes:)),
        payloadRevision: payload.revision), payload
    )
  }

  func testCountsGroupIssuedWithReviewAndTrackImportHistory() throws {
    var codes = try RecoveryCodeSet(
      text: "fixture-code-one\nfixture-code-two\nfixture-code-three\nfixture-code-four")
    _ = try codes.reserveNext()
    codes.setStatus(.used, for: codes.entries[1].id)
    codes.setStatus(.needsReview, for: codes.entries[2].id)
    XCTAssertEqual(
      RecoveryCodeCounts(codes: codes).listing, "codes=available:1,used:1,needs_review:2")
    var imported = try RecoveryCodeSet(
      text: "fixture-code-one\nfixture-code-two\nfixture-code-five")
    imported.preserveHistory(from: codes)
    XCTAssertEqual(
      RecoveryCodeCounts(codes: imported).listing, "codes=available:1,used:1,needs_review:1")
    imported.requireReviewAfterRestore()
    XCTAssertEqual(
      RecoveryCodeCounts(codes: imported).listing, "codes=available:0,used:1,needs_review:2")
  }

  func testReservationWritesConservativeMetadataBeforeSecretAndFinalRevisionAfterCommit() throws {
    let (item, payload) = try fixture()
    var metadata = item
    var stored = try payload.encoded()
    var events: [String] = []
    _ = try BrowserRecoveryPolicy.reserve(payload: payload, credential: item) { data in
      try RecoveryCodeMetadataCommit.reserve(
        data, credential: item,
        saveMetadata: {
          metadata = $0
          events.append("metadata")
        },
        saveSecret: {
          events.append("secret")
          XCTAssertEqual(metadata.recoveryCodeCounts?.available, 1)
          XCTAssertNotNil(metadata.recoveryCodePendingRevision)
          XCTAssertEqual(metadata.payloadRevision, item.payloadRevision)
          stored = $0
        })
    }
    XCTAssertEqual(events, ["metadata", "secret", "metadata"])
    let reloaded = try SensitivePayload.decode(stored, kind: .recoveryCodes)
    XCTAssertEqual(metadata.payloadRevision, reloaded.revision)
    XCTAssertNil(metadata.recoveryCodePendingRevision)
    XCTAssertEqual(metadata.recoveryCodeCounts?.listing, "codes=available:1,used:0,needs_review:1")
    XCTAssertTrue(
      CredentialSummary(metadata: metadata).recoveryListingFields.contains(
        "codes=available:1,used:0,needs_review:1"))
  }

  func testFailureAtEveryCommitBoundaryNeverOverReportsOrReleasesCode() throws {
    // 1: metadata preflight, 2: secret pre-commit, 3: metadata finalization.
    for failure in 1...3 {
      let (item, payload) = try fixture()
      var metadata = item
      var stored = try payload.encoded()
      var metadataWrites = 0
      var secretWrites = 0
      XCTAssertThrowsError(
        try BrowserRecoveryPolicy.reserve(payload: payload, credential: item) { data in
          try RecoveryCodeMetadataCommit.reserve(
            data, credential: item,
            saveMetadata: {
              metadataWrites += 1
              if (failure == 1 && metadataWrites == 1) || (failure == 3 && metadataWrites == 2) {
                throw SensitiveDataError.invalidPayload
              }
              metadata = $0
            },
            saveSecret: {
              secretWrites += 1
              if failure == 2 { throw SensitiveDataError.invalidPayload }
              stored = $0
            })
        })
      XCTAssertEqual(secretWrites, failure == 1 ? 0 : 1)
      let authoritative = try SensitivePayload.decode(stored, kind: .recoveryCodes)
      let actualCounts = RecoveryCodeCounts(codes: try XCTUnwrap(authoritative.recoveryCodes))
      XCTAssertLessThanOrEqual(
        try XCTUnwrap(metadata.recoveryCodeCounts?.available), actualCounts.available)
      if failure == 3 {
        XCTAssertNotNil(metadata.recoveryCodePendingRevision)
        XCTAssertThrowsError(try BrowserRecoveryPolicy.requireAvailable(metadata))
      }
      let repaired = try RecoveryCodeMetadataCommit.reconciled(metadata, payload: authoritative)
      XCTAssertEqual(repaired.recoveryCodeCounts, actualCounts)
      XCTAssertEqual(repaired.payloadRevision, authoritative.revision)
      XCTAssertNil(repaired.recoveryCodePendingRevision)
    }
  }

  func testCrashBeforeSecretAndFailedRollbackAreReconciledFromAuthenticatedOldPayload() throws {
    let (item, payload) = try fixture()
    var metadata = item
    var writes = 0
    XCTAssertThrowsError(
      try BrowserRecoveryPolicy.reserve(payload: payload, credential: item) { data in
        try RecoveryCodeMetadataCommit.reserve(
          data, credential: item,
          saveMetadata: {
            writes += 1
            guard writes == 1 else { throw SensitiveDataError.invalidPayload }
            metadata = $0
          }, saveSecret: { _ in throw SensitiveDataError.invalidPayload })
      })
    XCTAssertEqual(metadata.recoveryCodeCounts?.available, 1)
    XCTAssertNotNil(metadata.recoveryCodePendingRevision)
    let repaired = try RecoveryCodeMetadataCommit.reconciled(metadata, payload: payload)
    XCTAssertEqual(repaired.recoveryCodeCounts?.available, 2)
    XCTAssertNil(repaired.recoveryCodePendingRevision)
    var unrelated = payload
    unrelated.revision = UUID()
    XCTAssertThrowsError(try RecoveryCodeMetadataCommit.reconciled(metadata, payload: unrelated))
  }

  func testEditorCountsStayConservativeUntilSecretCommitAndCanRepairAfterRestart() throws {
    var (item, payload) = try fixture()
    let old = try XCTUnwrap(item.recoveryCodeCounts)
    payload.recoveryCodes = try RecoveryCodeSet(text: "new-code-one\nnew-code-two\nnew-code-three")
    payload.revision = UUID()
    let next = RecoveryCodeCounts(codes: try XCTUnwrap(payload.recoveryCodes))
    item.payloadRevision = payload.revision
    item.recoveryCodeCounts = next.staged(over: old)
    XCTAssertEqual(item.recoveryCodeCounts?.available, 2)
    XCTAssertEqual(next.staged(over: nil).available, 0)
    let repaired = try RecoveryCodeMetadataCommit.reconciled(item, payload: payload)
    XCTAssertEqual(repaired.recoveryCodeCounts?.available, 3)
    XCTAssertNil(repaired.recoveryCodePendingRevision)
  }

  func testFormatTwoRoundTripPreservesLinkAndCountsAndImportRecomputesRestoredStatuses() throws {
    let (item, payload) = try fixture()
    let contents = BackupContents(
      projects: [], credentials: [item], secrets: [item.id.uuidString: try payload.encoded()])
    let layout = try BackupArchive.layout(contents)
    let data = try XCTUnwrap(layout.first { $0.path == BackupArchive.dataFileName }?.data)
    let file = try JSONDecoder().decode(BackupArchive.DataFile.self, from: data)
    XCTAssertEqual(file.version, 2)
    let opened = try BackupArchive.contents(fromDataFile: data)
    XCTAssertEqual(opened, contents)
    let plan = BackupArchive.importPlan(opened, existingProjects: [], existingCredentialIDs: [])
    XCTAssertEqual(plan.newCredentials.first?.linkedLoginID, item.linkedLoginID)
    let restored = try SensitivePayload.decode(
      SensitivePayload.restored(try payload.encoded(), kind: .recoveryCodes), kind: .recoveryCodes)
    let imported = try RecoveryCodeMetadataCommit.reconciled(item, payload: restored)
    XCTAssertEqual(imported.linkedLoginID, item.linkedLoginID)
    XCTAssertEqual(imported.recoveryCodeCounts?.listing, "codes=available:0,used:0,needs_review:2")
    XCTAssertThrowsError(try BrowserRecoveryPolicy.requireAvailable(imported)) {
      XCTAssertEqual($0 as? ControlledBrowserError, .recoveryCodesExhausted)
    }
    var legacy = item
    legacy.recoveryCodeCounts = nil
    XCTAssertNoThrow(try BrowserRecoveryPolicy.requireAvailable(legacy))
    XCTAssertEqual(
      try RecoveryCodeMetadataCommit.reconciled(legacy, payload: payload).recoveryCodeCounts,
      item.recoveryCodeCounts)
  }
}
