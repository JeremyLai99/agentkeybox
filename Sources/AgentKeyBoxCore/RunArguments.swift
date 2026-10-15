import Foundation

/// Parses `akb run [--only A,B] [--] command args…`.
///
/// Parsing is strict because a mistake must never widen what a command receives: `--only`
/// without names, or an option `akb` does not know, is an error rather than "all keys".
public struct RunArguments: Equatable, Sendable {
  /// The variables to hand over, or nil for every key of the project.
  public var only: [String]?
  public var command: [String]

  public enum ParseError: Error, Equatable, LocalizedError {
    case missingCommand
    case missingOnlyValue
    case repeatedOnly
    case unknownOption(String)

    public var errorDescription: String? {
      switch self {
      case .missingCommand:
        return L("Usage: akb run [--only VAR1,VAR2] -- <command> [args…]")
      case .missingOnlyValue:
        return L("--only needs the names of the keys to pass, such as --only STRIPE_SECRET_KEY.")
      case .repeatedOnly:
        return L("--only can be given once; list the names separated by commas.")
      case .unknownOption(let option):
        return L("Unknown option for akb run: %@", option)
      }
    }
  }

  public static func parse(_ arguments: [String]) throws -> RunArguments {
    var only: [String]?
    var index = arguments.startIndex
    while index < arguments.endIndex {
      let argument = arguments[index]
      if argument == "--" {
        index += 1
        break
      }
      if argument == "--only" || argument.hasPrefix("--only=") {
        guard only == nil else { throw ParseError.repeatedOnly }
        let value: String
        if argument == "--only" {
          let next = index + 1
          guard next < arguments.endIndex, !arguments[next].hasPrefix("-") else {
            throw ParseError.missingOnlyValue
          }
          value = arguments[next]
          index = next + 1
        } else {
          value = String(argument.dropFirst("--only=".count))
          index += 1
        }
        let names = value.split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
        guard !names.isEmpty else { throw ParseError.missingOnlyValue }
        only = names
        continue
      }
      if argument.hasPrefix("-") { throw ParseError.unknownOption(argument) }
      break  // the command starts here
    }
    let command = Array(arguments[index...])
    guard !command.isEmpty else { throw ParseError.missingCommand }
    return RunArguments(only: only, command: command)
  }
}
