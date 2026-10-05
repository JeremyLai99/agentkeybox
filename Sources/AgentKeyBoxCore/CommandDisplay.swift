import Foundation

/// Renders a command for the approval prompt so that what the user reads is exactly what runs.
public enum CommandDisplay {
  /// One argument per line with control characters escaped and spaces quoted, so an argument
  /// cannot hide another behind newlines or masquerade as several arguments.
  public static func lines(executable: String, arguments: [String]) -> String {
    ([executable] + arguments).map(displayArgument).joined(separator: "\n")
  }

  public static func displayArgument(_ argument: String) -> String {
    var escaped = ""
    for scalar in argument.unicodeScalars {
      switch scalar {
      case "\n": escaped += "\\n"
      case "\r": escaped += "\\r"
      case "\t": escaped += "\\t"
      case "\"": escaped += "\\\""
      case "\\": escaped += "\\\\"
      default:
        if scalar.properties.generalCategory == .control
          || scalar.properties.generalCategory == .format
        {
          escaped += "\\u{\(String(scalar.value, radix: 16))}"
        } else {
          escaped.unicodeScalars.append(scalar)
        }
      }
    }
    let needsQuotes = argument.isEmpty || argument.contains(where: { $0.isWhitespace })
    return needsQuotes ? "\"\(escaped)\"" : escaped
  }
}
