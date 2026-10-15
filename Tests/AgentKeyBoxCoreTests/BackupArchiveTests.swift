import Foundation
import XCTest

@testable import AgentKeyBoxCore

final class BackupArchiveTests: XCTestCase {
  private let password = "correct horse battery"
  private let stripe = Data("sk_test_backup_0123456789".utf8)
  private let tricky = "line one\nsaid \"hi\" \\ $HOME #not-a-comment"
  private let p8 = Data("-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----\n".utf8)
  private let binary = Data([0xFF, 0xFE, 0x00, 0x01])

  private func sample() -> BackupContents {
    let app = Project(name: "my-app", rootPath: "/Users/someone/my-app")
    let ios = Project(name: "../ios:app", rootPath: "/Users/someone/ios")
    let duplicate = Project(name: "MY-APP", rootPath: "/Users/someone/other")
    let keys = [
      CredentialMetadata(
        label: "STRIPE_SECRET_KEY", service: "Stripe", projectID: app.id,
        environmentVariableName: "STRIPE_SECRET_KEY", allowedHosts: ["api.stripe.com"]),
      CredentialMetadata(
        label: "NOTE", service: "Custom", projectID: app.id, environmentVariableName: "NOTE"),
      CredentialMetadata(
        label: "App Store Connect key ABC123DEF4", service: "Apple App Store Connect",
        projectID: ios.id, kind: .p8,
        settings: ["ASC_KEY_ID": "ABC123DEF4", "ASC_ISSUER_ID": "issuer-1"]),
      CredentialMetadata(
        label: "BLOB", service: "Custom", projectID: duplicate.id,
        environmentVariableName: "BLOB"),
      CredentialMetadata(
        label: "loose.pem", service: "Private key", projectID: UUID(), kind: .pem),
      CredentialMetadata(label: "MISSING", service: "Custom", projectID: app.id),
    ]
    return BackupContents(
      createdAt: Date(timeIntervalSince1970: 1_800_000_000.25), projects: [app, ios, duplicate],
      credentials: keys,
      secrets: [
        keys[0].id.uuidString: stripe, keys[1].id.uuidString: Data(tricky.utf8),
        keys[2].id.uuidString: p8, keys[3].id.uuidString: binary,
        keys[4].id.uuidString: p8,
      ])
  }

  override func setUp() {
    super.setUp()
    Localization.setOverride(.english)
  }

  override func tearDown() {
    Localization.setOverride(nil)
    super.tearDown()
  }

  func testLayoutHasAFolderPerProjectWithItsEnvAndKeyFiles() throws {
    let contents = sample()
    let entries = try BackupArchive.layout(contents)
    let files = Dictionary(entries.map { ($0.path, $0.data) }, uniquingKeysWith: { a, _ in a })
    XCTAssertEqual(
      entries.map(\.path),
      [
        "_ios_app/AuthKey_ABC123DEF4.p8", "_ios_app/.env",
        "my-app/.env",
        "MY-APP 2/BLOB.txt",
        "No project/loose.pem",
        "README.txt", ".agentkeybox-backup.json", ".metadata_never_index",
      ])

    let env = EnvParser.parse(String(decoding: try XCTUnwrap(files["my-app/.env"]), as: UTF8.self))
    XCTAssertEqual(env, ["STRIPE_SECRET_KEY": String(decoding: stripe, as: UTF8.self), "NOTE": tricky])
    XCTAssertEqual(files["_ios_app/AuthKey_ABC123DEF4.p8"], p8)
    XCTAssertEqual(
      EnvParser.parse(String(decoding: try XCTUnwrap(files["_ios_app/.env"]), as: UTF8.self)),
      ["ASC_KEY_ID": "ABC123DEF4", "ASC_ISSUER_ID": "issuer-1"])
    XCTAssertEqual(files["MY-APP 2/BLOB.txt"], binary, "bytes that are not text stay a file")
    XCTAssertEqual(files["No project/loose.pem"], p8)

    let readme = String(decoding: try XCTUnwrap(files["README.txt"]), as: UTF8.self)
    XCTAssertTrue(readme.contains("STRIPE_SECRET_KEY (Stripe): in .env as STRIPE_SECRET_KEY"))
    XCTAssertTrue(readme.contains("MISSING (Custom): no key value, not included"))
    XCTAssertTrue(readme.contains("Allowed hosts: api.stripe.com"))
    XCTAssertFalse(readme.contains("sk_test_backup"), "the README never holds key values")

    let data = try XCTUnwrap(files[".agentkeybox-backup.json"])
    XCTAssertEqual(try BackupArchive.contents(fromDataFile: data), contents)
  }

  func testEnvLinesReadBackUnchanged() {
    for value in ["plain", "", "a b", "x=y#z", "quote\"back\\slash", "tab\tand\r\nlines", "日本"] {
      let line = BackupArchive.envLine("KEY", value)
      XCTAssertEqual(EnvParser.parse(line), ["KEY": value], line)
    }
  }

  func testDataFileRejectsOtherFilesAndNewerVersions() throws {
    XCTAssertThrowsError(try BackupArchive.contents(fromDataFile: Data("{}".utf8))) {
      XCTAssertEqual($0 as? BackupError, .notABackup)
    }
    let newer = Data(#"{"format":"agentkeybox-backup","version":2}"#.utf8)
    XCTAssertThrowsError(try BackupArchive.contents(fromDataFile: newer)) {
      XCTAssertEqual($0 as? BackupError, .unsupportedVersion)
    }
  }

  func testRejectsShortPasswords() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("unused.dmg")
    XCTAssertThrowsError(try BackupArchive.write(sample(), password: "short", to: url)) {
      XCTAssertEqual($0 as? BackupError, .passwordTooShort)
    }
  }

  #if os(macOS)
    func testEncryptedDiskImageOpensOnlyWithThePassword() throws {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentKeyBoxBackupTest-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let url = folder.appendingPathComponent("backup.dmg")
      let contents = sample()

      try BackupArchive.write(contents, password: password, to: url)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
      let file = try Data(contentsOf: url)
      XCTAssertNil(file.range(of: stripe), "the key must not appear in the file")
      XCTAssertNil(file.range(of: Data("STRIPE_SECRET_KEY".utf8)), "names are encrypted too")
      XCTAssertEqual(try BackupArchive.read(from: url, password: password), contents)

      XCTAssertThrowsError(try BackupArchive.read(from: url, password: password + "!")) {
        XCTAssertEqual($0 as? BackupError, .wrongPasswordOrDamaged)
      }

      // Exporting again over the same file replaces it.
      var newer = contents
      newer.appVersion = "next"
      try BackupArchive.write(newer, password: password, to: url)
      XCTAssertEqual(try BackupArchive.read(from: url, password: password).appVersion, "next")

      let text = folder.appendingPathComponent("notes.dmg")
      try Data("not a disk image".utf8).write(to: text)
      XCTAssertThrowsError(try BackupArchive.read(from: text, password: password)) {
        XCTAssertEqual($0 as? BackupError, .notABackup)
      }
    }
  #endif
}
