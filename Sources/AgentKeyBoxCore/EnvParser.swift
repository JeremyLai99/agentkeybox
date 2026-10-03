import Foundation

public enum EnvParser {
  public static func parse(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    let lines = text.components(separatedBy: .newlines)
    var index = 0

    while index < lines.count {
      var line = lines[index].trimmingCharacters(in: .whitespaces)
      index += 1

      guard !line.isEmpty, !line.hasPrefix("#") else { continue }

      if line.hasPrefix("export ") {
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
        result[key] = quote == "\"" ? decodeDoubleQuoted(joined) : joined
      } else {
        result[key] = stripInlineComment(rawValue).trimmingCharacters(in: .whitespaces)
      }
    }

    return result
  }

  private static func isValidKey(_ key: String) -> Bool {
    guard let first = key.first, first == "_" || first.isLetter else { return false }
    return key.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
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
