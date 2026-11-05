import XCTest

@testable import AgentKeyBoxCore

final class RecoverableSecretReplacementTests: XCTestCase {
  private typealias Slot = RecoverableSecretReplacement.Slot
  private let old = Data("synthetic-old".utf8)
  private let new = Data("synthetic-new".utf8)

  private final class Storage {
    enum Failure: Error { case injected, duplicate }
    var values: [Slot: Data] = [:]
    var failBefore: Int?
    var interruptAfter: Int?
    var failRead: Slot?
    var mutations = 0
    var reads: [Slot] = []

    func mutate(_ body: () throws -> Void) throws {
      mutations += 1
      if mutations == failBefore { throw Failure.injected }
      try body()
      if mutations == interruptAfter { throw Failure.injected }
    }

    var replacement: RecoverableSecretReplacement {
      RecoverableSecretReplacement(
        add: { slot, data in
          try self.mutate {
            guard self.values[slot] == nil else { throw Failure.duplicate }
            self.values[slot] = data
          }
        },
        read: { slot in
          self.reads.append(slot)
          if self.failRead == slot { throw Failure.injected }
          return self.values[slot]
        },
        remove: { slot in try self.mutate { self.values[slot] = nil } })
    }

    func restart() {
      failBefore = nil
      interruptAfter = nil
      failRead = nil
      mutations = 0
      reads = []
    }
  }

  func testFailureBeforeEveryReplacementStepRetainsOldOrNew() throws {
    for step in 1...4 {
      let store = Storage()
      store.values = [.primary: old]
      store.failBefore = step
      XCTAssertThrowsError(try store.replacement.save(new))
      XCTAssertTrue(store.values.values.contains(old) || store.values.values.contains(new))
      store.restart()
      XCTAssertEqual(try store.replacement.load(), step == 1 ? old : new)
      XCTAssertNil(store.values[.pending])
    }
  }

  func testInterruptionAfterEveryReplacementStepRecoversLatest() throws {
    for step in 1...4 {
      let store = Storage()
      store.values = [.primary: old]
      store.interruptAfter = step
      XCTAssertThrowsError(try store.replacement.save(new))
      store.restart()
      XCTAssertEqual(try store.replacement.load(), new)
      XCTAssertEqual(store.values, [.primary: new])
    }
  }

  func testInitialCreationFailureAndInterruptions() throws {
    let store = Storage()
    store.failBefore = 1
    XCTAssertThrowsError(try store.replacement.save(new))
    XCTAssertTrue(store.values.isEmpty)
    for step in 1...4 {
      store.values = [:]
      store.restart()
      store.interruptAfter = step
      XCTAssertThrowsError(try store.replacement.save(new))
      store.restart()
      XCTAssertEqual(try store.replacement.load(), new)
    }
  }

  func testPendingCannotBeOverwrittenOrMistakenForAnOlderValue() throws {
    for primary in [nil, old, new] as [Data?] {
      let store = Storage()
      store.values = [.pending: new]
      store.values[.primary] = primary
      let newest = Data("synthetic-newest".utf8)
      XCTAssertThrowsError(try store.replacement.save(newest))
      XCTAssertEqual(store.values[.pending], new)
      XCTAssertEqual(try store.replacement.load(), new)
      try store.replacement.save(newest)
      XCTAssertEqual(try store.replacement.load(), newest)
      XCTAssertEqual(store.values, [.primary: newest])
    }
  }

  func testReadAuthenticationFailureNeverFallsBackToOldPrimary() {
    let store = Storage()
    store.values = [.primary: old, .pending: new]
    store.failRead = .pending
    XCTAssertThrowsError(try store.replacement.load())
    XCTAssertEqual(store.reads, [.pending])
    XCTAssertEqual(store.mutations, 0)
  }

  func testRepairFailureOrInterruptionNeverLosesLatestAndReadsOnlyOneValue() throws {
    for interrupted in [false, true] {
      for step in 1...3 {
        let store = Storage()
        store.values = [.primary: old, .pending: new]
        if interrupted { store.interruptAfter = step } else { store.failBefore = step }
        XCTAssertEqual(try store.replacement.load(), new)
        XCTAssertEqual(store.reads, [.pending])
        store.restart()
        XCTAssertEqual(try store.replacement.load(), new)
      }
    }
  }

  func testDeleteRemovesBothSlotsAndFailureCannotResurrectOldPrimary() throws {
    for step in 1...2 {
      let store = Storage()
      store.values = [.primary: old, .pending: new]
      store.failBefore = step
      XCTAssertThrowsError(try store.replacement.delete())
      store.restart()
      XCTAssertEqual(try store.replacement.load(), new)
      try store.replacement.delete()
      XCTAssertNil(try store.replacement.load())
    }
    let store = Storage()
    store.values = [.pending: new]
    try store.replacement.delete()
    XCTAssertTrue(store.values.isEmpty)
  }

  @MainActor
  func testRecoveredReservationCannotResurrectIssuedCodeAndOldRevisionIsRejected() async throws {
    let original = SensitivePayload(
      recoveryCodes: try RecoveryCodeSet(text: "synthetic-code-001\nsynthetic-code-002"))
    var item = CredentialMetadata(
      label: "Fixture", service: "Fixture", kind: .recoveryCodes,
      submissionURL: "https://fixture.invalid/recovery", payloadRevision: original.revision)
    let store = Storage()
    store.values[.primary] = try original.encoded()
    store.failBefore = 2
    XCTAssertThrowsError(
      try BrowserRecoveryPolicy.reserve(payload: original, credential: item) {
        try store.replacement.save($0)
      })
    store.restart()
    let recovered = try SensitivePayload.decode(
      XCTUnwrap(store.replacement.load()), kind: .recoveryCodes)
    XCTAssertNotEqual(recovered.revision, original.revision)
    XCTAssertEqual(recovered.recoveryCodes?.entries.map(\.status), [.issued, .available])
    // If metadata survived with the new revision, any older payload must fail both use paths.
    item.payloadRevision = recovered.revision
    XCTAssertThrowsError(
      try BrowserRecoveryPolicy.reserve(payload: original, credential: item) { _ in
        XCTFail("Old revision must never be persisted")
      })
    do {
      _ = try await SensitiveSubmissionExecutor.execute(
        .init(fields: ["code": "{{recovery.code}}"]), credential: item, payload: original,
        persistReservation: { _ in XCTFail("Old revision must not be saved") },
        send: { _ in
          XCTFail("Old revision must not be sent")
          return .received
        })
      XCTFail("Stale revision must fail")
    } catch SensitiveDataError.invalidPayload {}
    let next = try BrowserRecoveryPolicy.reserve(payload: recovered, credential: item) {
      try store.replacement.save($0)
    }
    XCTAssertEqual(next, "synthetic-code-002")
  }
}
