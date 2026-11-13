import Foundation
import XCTest

final class TestProductsTests: XCTestCase {
  private func withProducts(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["agentkeybox-mcp", "akb"] {
      let file = root.appendingPathComponent(name)
      try Data("synthetic executable fixture; never launched".utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    try body(root)
  }

  func testFindsProductsBesideMacOSTestBundle() throws {
    try withProducts { products in
      for name in ["agentkeybox-mcp", "akb"] {
        XCTAssertEqual(
          try TestProducts.executable(
            name, bundleURL: products.appendingPathComponent("Tests.xctest"), environment: [:]),
          products.appendingPathComponent(name))
      }
    }
  }

  func testFindsProductsWhenLinuxBundleIsProductsDirectory() throws {
    try withProducts { products in
      XCTAssertEqual(
        try TestProducts.executable("akb", bundleURL: products, environment: [:]),
        products.appendingPathComponent("akb"))
    }
  }

  func testExplicitProductsOverrideWins() throws {
    try withProducts { products in
      XCTAssertEqual(
        try TestProducts.executable(
          "akb", bundleURL: products.appendingPathComponent("absent/Tests.xctest"),
          environment: ["AGENTKEYBOX_TEST_BIN_DIR": products.path]),
        products.appendingPathComponent("akb"))
    }
  }

  func testMissingProductSkipsLocallyButFailsWhenRequiredByCI() throws {
    try withProducts { products in
      for required in [false, true] {
        XCTAssertThrowsError(
          try TestProducts.executable(
            "absent", bundleURL: products,
            environment: ["AGENTKEYBOX_REQUIRE_PROCESS_TESTS": required ? "1" : "0"])
        ) { error in
          if required {
            XCTAssertTrue(error is TestProducts.MissingExecutable)
            XCTAssertTrue(String(describing: error).contains("swift build"))
          } else {
            XCTAssertTrue(error is XCTSkip)
          }
        }
      }
    }
  }
}
