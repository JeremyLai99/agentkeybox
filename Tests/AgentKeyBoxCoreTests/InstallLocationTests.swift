import Foundation
import XCTest

@testable import AgentKeyBoxCore

#if canImport(Darwin)
  import Darwin
#endif

final class InstallLocationTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "akb-install-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testHelperIsCopiedToAFixedPathAndRefreshedWhenTheAppChanges() throws {
    let bundled = root.appendingPathComponent("Old.app/Contents/Helpers/agentkeybox-mcp")
    try FileManager.default.createDirectory(
      at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("version 1".utf8).write(to: bundled)
    let fixed = root.appendingPathComponent("support/bin/agentkeybox-mcp")

    XCTAssertEqual(try HelperInstaller.install(from: bundled, to: fixed), fixed.path)
    XCTAssertEqual(try Data(contentsOf: fixed), Data("version 1".utf8))
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixed.path))
    let modified = try FileManager.default.attributesOfItem(atPath: fixed.path)[.modificationDate]

    // Same content: left alone.
    try HelperInstaller.install(from: bundled, to: fixed)
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: fixed.path)[.modificationDate] as? Date,
      modified as? Date)

    // The app was updated or moved: the fixed copy follows, and the path stays the same.
    let moved = root.appendingPathComponent("Applications/AgentKeyBox.app/agentkeybox-mcp")
    try FileManager.default.createDirectory(
      at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("version 2".utf8).write(to: moved)
    XCTAssertEqual(try HelperInstaller.install(from: moved, to: fixed), fixed.path)
    XCTAssertEqual(try Data(contentsOf: fixed), Data("version 2".utf8))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: fixed.deletingLastPathComponent().path),
      ["agentkeybox-mcp"], "no temporary files are left behind")

    XCTAssertEqual(try HelperInstaller.install(from: fixed, to: fixed), fixed.path)
    XCTAssertTrue(HelperInstaller.installedHelperURL.path.hasSuffix("AgentKeyBox/bin/agentkeybox-mcp"))
  }

  func testWhereTheAppRunsDecidesWhetherToOfferTheMove() {
    let home = URL(fileURLWithPath: "/Users/someone")
    XCTAssertTrue(
      InstallLocation.isInApplications(URL(fileURLWithPath: "/Applications/AgentKeyBox.app"), home: home))
    XCTAssertTrue(
      InstallLocation.isInApplications(
        URL(fileURLWithPath: "/Users/someone/Applications/AgentKeyBox.app"), home: home))
    XCTAssertFalse(
      InstallLocation.isInApplications(
        URL(fileURLWithPath: "/Users/someone/Downloads/AgentKeyBox.app"), home: home))

    let translocated = URL(
      fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/1234/d/AgentKeyBox.app")
    XCTAssertTrue(InstallLocation.isTranslocated(translocated))
    XCTAssertTrue(InstallLocation.shouldOfferMove(translocated))
    XCTAssertFalse(InstallLocation.isTranslocated(URL(fileURLWithPath: "/Applications/AgentKeyBox.app")))
    XCTAssertFalse(InstallLocation.shouldOfferMove(URL(fileURLWithPath: "/Applications/AgentKeyBox.app")))
    XCTAssertFalse(
      InstallLocation.shouldOfferMove(URL(fileURLWithPath: "/tmp/.build/debug")),
      "swift run is not an app bundle")
  }

  #if canImport(Darwin)
    func testMovedAppIsNoLongerQuarantinedAndReplacesAnOlderCopy() throws {
      let source = root.appendingPathComponent("Downloads/AgentKeyBox.app")
      let binary = source.appendingPathComponent("Contents/MacOS/AgentKeyBox")
      try FileManager.default.createDirectory(
        at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("app".utf8).write(to: binary)
      let flag = "0083;00000000;Safari;"
      XCTAssertEqual(setxattr(binary.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0), 0)

      let destination = root.appendingPathComponent("Applications/AgentKeyBox.app")
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try Data("old".utf8).write(to: destination.appendingPathComponent("old-version"))

      // Removed directly here; the app moves an older copy to the user's Trash.
      var replaced: URL?
      try InstallLocation.copyApp(from: source, to: destination) { old in
        replaced = old
        try FileManager.default.removeItem(at: old)
      }
      XCTAssertEqual(replaced, destination)
      let copied = destination.appendingPathComponent("Contents/MacOS/AgentKeyBox")
      XCTAssertEqual(try Data(contentsOf: copied), Data("app".utf8))
      XCTAssertEqual(getxattr(copied.path, "com.apple.quarantine", nil, 0, 0, 0), -1)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: destination.appendingPathComponent("old-version").path),
        "the older copy is replaced")
    }
  #endif
}
