import Foundation
import XCTest

@testable import AgentKeyBoxCore

final class LocalizationTests: XCTestCase {
  override func tearDown() {
    Localization.setOverride(nil)
    super.tearDown()
  }

  /// Every `L("…")` in the sources, as the runtime string it looks up.
  private func localizedKeysInSources() throws -> [String: String] {
    let sources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources")
    let pattern = try NSRegularExpression(pattern: #"\bL\(\s*"((?:[^"\\]|\\.)*)""#)
    var keys: [String: String] = [:]
    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
    while let file = files?.nextObject() as? URL {
      guard file.pathExtension == "swift", file.lastPathComponent != "Translations.swift" else {
        continue
      }
      let text = try String(contentsOf: file, encoding: .utf8)
      let range = NSRange(text.startIndex..., in: text)
      for match in pattern.matches(in: text, range: range) {
        guard let literal = Range(match.range(at: 1), in: text).map({ String(text[$0]) }) else {
          continue
        }
        let key = literal.replacingOccurrences(of: #"\""#, with: "\"")
          .replacingOccurrences(of: #"\\"#, with: "\\")
        keys[key] = file.lastPathComponent
      }
    }
    return keys
  }

  func testEveryInterfaceStringHasATraditionalChineseTranslation() throws {
    let keys = try localizedKeysInSources()
    XCTAssertGreaterThan(keys.count, 200, "the scan should find the interface strings")
    for (key, file) in keys.sorted(by: { $0.key < $1.key }) {
      XCTAssertFalse(key.contains(#"\("#), "\(file): interpolate with %@ instead: \(key)")
      XCTAssertNotNil(
        Translations.traditionalChinese[key], "\(file): missing translation for \(key)")
    }
    // Labels translated where they are shown rather than where they are written.
    for setting in ProviderCatalog.all.flatMap(\.settings) {
      XCTAssertNotNil(Translations.traditionalChinese[setting.label], setting.label)
    }
  }

  func testTranslationsKeepTheirPlaceholders() {
    func placeholders(_ text: String) -> Int {
      let positional = text.components(separatedBy: "$@").count - 1
      return positional > 0 ? positional : text.components(separatedBy: "%@").count - 1
    }
    for (english, chinese) in Translations.traditionalChinese {
      XCTAssertEqual(placeholders(english), placeholders(chinese), english)
    }
  }

  func testLanguageFollowsPreferenceAndFormatsArguments() {
    Localization.setOverride(.traditionalChinese)
    XCTAssertEqual(L("Allow Once"), "允許一次")
    XCTAssertEqual(L("%@ wants to use your %@ key", "Claude Code", "Stripe"), "Claude Code 想使用你的 Stripe 金鑰")
    XCTAssertEqual(L("Saved %@ for %@.", "STRIPE_SECRET_KEY", "my-app"), "已為 my-app 儲存 STRIPE_SECRET_KEY。")
    XCTAssertEqual(L("Text nobody translated"), "Text nobody translated", "falls back to English")

    Localization.setOverride(.english)
    XCTAssertEqual(L("Allow Once"), "Allow Once")
    XCTAssertEqual(L("Saved %@ for %@.", "A", "B"), "Saved A for B.")
  }

  func testSystemLanguageMatching() {
    XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["zh-Hant-TW", "en"]), .traditionalChinese)
    XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["zh-HK"]), .traditionalChinese)
    XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["zh-Hans-CN"]), .english)
    XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["ja-JP", "zh-Hant"]), .english)
    XCTAssertEqual(AppLanguage.matching(preferredLanguages: []), .english)
  }

  func testChineseCardTextAndLists() {
    Localization.setOverride(.traditionalChinese)
    let key = CredentialMetadata(
      label: "App Store Connect key ABC123DEF4", service: "Apple App Store Connect", kind: .p8,
      settings: ["ASC_KEY_ID": "ABC123DEF4"])
    XCTAssertEqual(CredentialCardText.attention(for: key)?.message, "還缺發行者 ID（Issuer ID）")
    XCTAssertEqual(ProviderBundles.includes(for: key), "包含金鑰 ID（Key ID）")
    XCTAssertEqual(ProviderBundles.listed(["A", "B", "C"]), "A、B 和 C")
  }
}
