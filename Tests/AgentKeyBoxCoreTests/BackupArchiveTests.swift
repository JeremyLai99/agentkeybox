import Foundation
import XCTest

@testable import AgentKeyBoxCore

#if canImport(CryptoKit) && canImport(CommonCrypto)
  final class BackupArchiveTests: XCTestCase {
    private let password = "correct horse battery"
    private let secret = Data("sk_live_backup_test_0123456789".utf8)

    private func sample() -> BackupContents {
      let project = Project(name: "my-app", rootPath: "/Users/someone/my-app")
      let key = CredentialMetadata(
        label: "STRIPE_SECRET_KEY", service: "Stripe", projectID: project.id,
        environmentVariableName: "STRIPE_SECRET_KEY", allowedHosts: ["api.stripe.com"])
      return BackupContents(
        createdAt: Date(timeIntervalSince1970: 1_800_000_000), projects: [project],
        credentials: [key], secrets: [key.id.uuidString: secret])
    }

    override func setUp() {
      super.setUp()
      Localization.setOverride(.english)
    }

    override func tearDown() {
      Localization.setOverride(nil)
      super.tearDown()
    }

    func testRoundTripAndNoPlaintextInTheFile() throws {
      let contents = sample()
      let file = try BackupArchive.encrypt(contents, password: password, iterations: 10_000)
      XCTAssertNil(
        file.range(of: secret), "the key must not appear in the file")
      XCTAssertNil(file.range(of: Data(secret.base64EncodedString().utf8)))
      XCTAssertNil(file.range(of: Data("STRIPE_SECRET_KEY".utf8)), "metadata is encrypted too")
      XCTAssertEqual(try BackupArchive.decrypt(file, password: password), contents)
    }

    func testWrongPasswordFails() throws {
      let file = try BackupArchive.encrypt(sample(), password: password, iterations: 10_000)
      XCTAssertThrowsError(try BackupArchive.decrypt(file, password: password + "!")) {
        XCTAssertEqual($0 as? BackupError, .wrongPasswordOrDamaged)
      }
    }

    func testAnyChangeToTheFileIsDetected() throws {
      let file = try BackupArchive.encrypt(sample(), password: password, iterations: 10_000)
      var envelope = try XCTUnwrap(
        JSONSerialization.jsonObject(with: file) as? [String: Any])

      // A flipped ciphertext byte.
      var sealed = try XCTUnwrap(Data(base64Encoded: envelope["sealed"] as! String))
      sealed[sealed.count / 2] ^= 0x01
      var tampered = envelope
      tampered["sealed"] = sealed.base64EncodedString()
      XCTAssertThrowsError(
        try BackupArchive.decrypt(JSONSerialization.data(withJSONObject: tampered), password: password))

      // A changed parameter is caught by the authenticated header, even a valid-looking one.
      envelope["iterations"] = 20_000
      XCTAssertThrowsError(
        try BackupArchive.decrypt(JSONSerialization.data(withJSONObject: envelope), password: password)
      ) { XCTAssertEqual($0 as? BackupError, .wrongPasswordOrDamaged) }
    }

    func testRejectsWeakPasswordsHostileParametersAndOtherFiles() throws {
      XCTAssertThrowsError(try BackupArchive.encrypt(sample(), password: "short")) {
        XCTAssertEqual($0 as? BackupError, .passwordTooShort)
      }
      XCTAssertThrowsError(try BackupArchive.decrypt(Data("{}".utf8), password: password)) {
        XCTAssertEqual($0 as? BackupError, .notABackup)
      }
      let file = try BackupArchive.encrypt(sample(), password: password, iterations: 10_000)
      var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: file) as? [String: Any])
      envelope["iterations"] = 1
      XCTAssertThrowsError(
        try BackupArchive.decrypt(JSONSerialization.data(withJSONObject: envelope), password: password)
      ) { XCTAssertEqual($0 as? BackupError, .notABackup) }
      envelope["iterations"] = 10_000
      envelope["version"] = 99
      XCTAssertThrowsError(
        try BackupArchive.decrypt(JSONSerialization.data(withJSONObject: envelope), password: password)
      ) { XCTAssertEqual($0 as? BackupError, .unsupportedVersion) }
    }

    func testDefaultKeyDerivationIsSlowEnoughToResistGuessing() throws {
      XCTAssertGreaterThanOrEqual(BackupArchive.defaultIterations, 600_000)
      let start = Date()
      _ = try BackupArchive.deriveKey(
        password: password, salt: Data(repeating: 7, count: 16),
        iterations: BackupArchive.defaultIterations)
      XCTAssertLessThan(Date().timeIntervalSince(start), 5, "but still quick for the user")
    }
  }
#endif
