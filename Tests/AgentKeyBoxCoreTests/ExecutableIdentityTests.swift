import Foundation
import XCTest

@testable import AgentKeyBoxCore

#if os(macOS)
  import Darwin
#else
  import Glibc
#endif

final class ExecutableIdentityTests: XCTestCase {
  private let rejection = "Requests must come from the AgentKeyBox helper or akb."

  private func withFile(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("helper")
    try Data("original".utf8).write(to: file)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: file.path)
    try body(file)
  }

  func testUnchangedFileAndReadsKeepIdentity() throws {
    try withFile { file in
      let snapshot = try XCTUnwrap(ExecutableIdentity(url: file))
      _ = try Data(contentsOf: file)
      XCTAssertFalse(snapshot.hasChanged)
    }
  }

  func testInPlaceRewriteWithSameSizeIsDetected() throws {
    try withFile { file in
      let snapshot = try XCTUnwrap(ExecutableIdentity(url: file))
      let before = try FileManager.default.attributesOfItem(atPath: file.path)
      let handle = try FileHandle(forWritingTo: file)
      try handle.write(contentsOf: Data("modified".utf8))
      try handle.close()
      let after = try FileManager.default.attributesOfItem(atPath: file.path)
      XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
      XCTAssertEqual(before[.size] as? NSNumber, after[.size] as? NSNumber)
      XCTAssertTrue(snapshot.hasChanged)
    }
  }

  func testRenameReplacementIncludingIdenticalContentsIsDetected() throws {
    for contents in ["a different executable", "original"] {
      try withFile { file in
        let snapshot = try XCTUnwrap(ExecutableIdentity(url: file))
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let replacement = file.appendingPathExtension("new")
        try Data(contents.utf8).write(to: replacement)
        try FileManager.default.setAttributes(
          [.modificationDate: try XCTUnwrap(before[.modificationDate])],
          ofItemAtPath: replacement.path)
        XCTAssertEqual(rename(replacement.path, file.path), 0)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertNotEqual(
          before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertTrue(snapshot.hasChanged)
      }
    }
  }

  func testSymlinkTargetReplacementAndRetargetingAreDetected() throws {
    try withFile { file in
      let link = file.appendingPathExtension("link")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
      let snapshot = try XCTUnwrap(ExecutableIdentity(url: link))
      XCTAssertFalse(snapshot.hasChanged)
      let replacement = file.appendingPathExtension("new")
      try Data("original".utf8).write(to: replacement)
      XCTAssertEqual(rename(replacement.path, file.path), 0)
      XCTAssertTrue(snapshot.hasChanged)

      let newSnapshot = try XCTUnwrap(ExecutableIdentity(url: link))
      try Data("original".utf8).write(to: replacement)
      try FileManager.default.removeItem(at: link)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: replacement)
      XCTAssertTrue(newSnapshot.hasChanged)
    }
  }

  func testOnlyExactPeerRejectionWithChangedExecutableIsMapped() throws {
    try withFile { file in
      let snapshot = try XCTUnwrap(ExecutableIdentity(url: file))
      for kind in [BrokerClientKind.mcpHelper, .commandLine] {
        XCTAssertEqual(
          kind.rejectionError(message: rejection, executable: snapshot), .requestFailed(rejection))
      }
      try Data("replacement".utf8).write(to: file, options: .atomic)
      for kind in [BrokerClientKind.mcpHelper, .commandLine] {
        XCTAssertEqual(
          kind.rejectionError(message: rejection, executable: snapshot), .clientUpdated(kind))
        for message in [
          "Approval timed out.", "Unauthorized local broker request.",
          "Only akb run can request this.",
          rejection + " ", rejection + " private-diagnostic", "",
        ] {
          XCTAssertEqual(
            kind.rejectionError(message: message, executable: snapshot), .requestFailed(message))
        }
      }
    }
  }

  func testMissingSnapshotOrUnreadableCurrentIdentityKeepsRejection() throws {
    try withFile { file in
      let snapshot = try XCTUnwrap(ExecutableIdentity(url: file))
      try FileManager.default.removeItem(at: file)
      XCTAssertNil(ExecutableIdentity(url: file))
      XCTAssertFalse(snapshot.hasChanged)
      for executable in [snapshot, nil] {
        XCTAssertEqual(
          BrokerClientKind.mcpHelper.rejectionError(message: rejection, executable: executable),
          .requestFailed(rejection))
      }
    }
  }

  func testLocalizedUpdateMessagesCrossControlledBoundaryWithoutRawDiagnostics() {
    defer { Localization.setOverride(nil) }
    for language in [AppLanguage.english, .traditionalChinese] {
      Localization.setOverride(language)
      for kind in [BrokerClientKind.mcpHelper, .commandLine] {
        let error = BrokerError.clientUpdated(kind)
        XCTAssertEqual(error.controlledApprovalMessage, error.localizedDescription)
        XCTAssertNil(BrokerError.requestFailed(kind.updatedMessage).controlledApprovalMessage)
        XCTAssertNil(
          BrokerError.requestFailed(kind.updatedMessage + " private-diagnostic")
            .controlledApprovalMessage)
      }
      XCTAssertTrue(
        BrokerClientKind.mcpHelper.updatedMessage.contains("/mcp → agentkeybox → Reconnect"))
      XCTAssertEqual(
        BrokerClientKind.commandLine.updatedMessage,
        language == .english
          ? "AgentKeyBox was updated. Run this command again." : "AgentKeyBox 已更新。請重新執行這個指令。")
      XCTAssertTrue(
        BrokerClientKind.mcpHelper.updatedMessage.hasPrefix(
          language == .english ? "AgentKeyBox was updated," : "AgentKeyBox 已更新，"))
    }
    XCTAssertNil(BrokerError.requestFailed(rejection).controlledApprovalMessage)
  }
}
