import Foundation

public enum EnvParser {
  /// One `KEY=value` entry and the lines it spans (more than one for a multi-line quoted value).
  public struct Assignment: Equatable, Sendable {
    public var key: String
    public var value: String
    public var lines: Range<Int>
    public var exported: Bool
  }

  /// Later assignments of the same key win, as in dotenv.
  public static func parse(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for assignment in assignments(in: text) { result[assignment.key] = assignment.value }
    return result
  }

  /// Every assignment in file order, with line numbers into
  /// `text.components(separatedBy: .newlines)`.
  public static func assignments(in text: String) -> [Assignment] {
    var result: [Assignment] = []
    let lines = text.components(separatedBy: .newlines)
    var index = 0

    while index < lines.count {
      let start = index
      var line = lines[index].trimmingCharacters(in: .whitespaces)
      index += 1
      var exported = false

      guard !line.isEmpty, !line.hasPrefix("#") else { continue }

      if line.hasPrefix("export ") {
        exported = true
        line.removeFirst("export ".count)
        line = line.trimmingCharacters(in: .whitespaces)
      }

      guard let equals = line.firstIndex(of: "=") else { continue }
      let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
      guard isValidKey(key) else { continue }

      var rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)

      if let quote = rawValue.first, quote == "\"" || quote == "'" {
        rawValue.removeFirst()
        var chunks: [String] = []
        var current = rawValue

        while true {
          if let closing = closingQuoteIndex(in: current, quote: quote) {
            chunks.append(String(current[..<closing]))
            break
          }
          chunks.append(current)
          guard index < lines.count else { break }
          current = lines[index]
          index += 1
        }

        let joined = chunks.joined(separator: "\n")
        result.append(
          Assignment(
            key: key, value: quote == "\"" ? decodeDoubleQuoted(joined) : joined,
            lines: start..<index, exported: exported))
      } else {
        result.append(
          Assignment(
            key: key, value: stripInlineComment(rawValue).trimmingCharacters(in: .whitespaces),
            lines: start..<index, exported: exported))
      }
    }

    return result
  }

  /// Empties the given keys in a `.env` file's text, leaving a comment that says where the key
  /// is now, and every other line exactly as it was. All assignments of a key are emptied.
  /// Returns nil for text with Windows line endings, which is left alone.
  public static func removingValues(of keys: Set<String>, from text: String)
    -> (text: String, removed: [String])?
  {
    var lines = text.components(separatedBy: "\n")
    // Line numbers come from splitting on every newline character; only rewrite when that
    // matches splitting on "\n" (no "\r\n" or Unicode line separators).
    guard lines.count == text.components(separatedBy: .newlines).count else { return nil }
    var removed: [String] = []
    for assignment in assignments(in: text).reversed() where keys.contains(assignment.key) {
      let prefix = assignment.exported ? "export " : ""
      lines.replaceSubrange(
        assignment.lines,
        with: [
          "# \(assignment.key) is stored in AgentKeyBox. Start your app with: akb run -- <your command>",
          "\(prefix)\(assignment.key)=",
        ])
      if !removed.contains(assignment.key) { removed.insert(assignment.key, at: 0) }
    }
    return (lines.joined(separator: "\n"), removed)
  }

  private static func isValidKey(_ key: String) -> Bool {
    ApprovedCommandRunner.isValidEnvironmentVariable(key)
  }

  private static func closingQuoteIndex(in value: String, quote: Character) -> String.Index? {
    var escaped = false
    for index in value.indices {
      let char = value[index]
      if quote == "\"" && char == "\\" && !escaped {
        escaped = true
        continue
      }
      if char == quote && !escaped {
        return index
      }
      escaped = false
    }
    return nil
  }

  private static func stripInlineComment(_ value: String) -> String {
    var previousWasWhitespace = false
    for index in value.indices {
      let char = value[index]
      if char == "#" && previousWasWhitespace {
        return String(value[..<index])
      }
      previousWasWhitespace = char.isWhitespace
    }
    return value
  }

  private static func decodeDoubleQuoted(_ value: String) -> String {
    var output = ""
    var iterator = value.makeIterator()
    while let char = iterator.next() {
      guard char == "\\" else {
        output.append(char)
        continue
      }
      guard let next = iterator.next() else {
        output.append("\\")
        break
      }
      switch next {
      case "n": output.append("\n")
      case "r": output.append("\r")
      case "t": output.append("\t")
      case "\"": output.append("\"")
      case "\\": output.append("\\")
      default:
        output.append("\\")
        output.append(next)
      }
    }
    return output
  }
}
