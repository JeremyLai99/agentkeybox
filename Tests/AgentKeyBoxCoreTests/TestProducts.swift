import Foundation
import XCTest

/// Process fixtures use built products without linking executable targets into the test runner.
enum TestProducts {
  struct MissingExecutable: Error, CustomStringConvertible {
    let description: String
  }

  static func executable(
    _ name: String, bundleURL: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> URL {
    let products: URL
    if let override = environment["AGENTKEYBOX_TEST_BIN_DIR"] {
      products = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      // macOS: products/Tests.xctest. Linux Foundation can return the products directory.
      products =
        bundleURL.pathExtension == "xctest" ? bundleURL.deletingLastPathComponent() : bundleURL
    }
    let executable = products.appendingPathComponent(name)
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      let message =
        "Missing process-test product: \(executable.path). Run swift build with the same "
        + "configuration/scratch path as swift test, or set AGENTKEYBOX_TEST_BIN_DIR."
      if environment["AGENTKEYBOX_REQUIRE_PROCESS_TESTS"] == "1" {
        throw MissingExecutable(description: message)
      }
      throw XCTSkip(message)
    }
    return executable
  }
}
