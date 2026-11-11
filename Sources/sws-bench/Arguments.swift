/// Minimal hand-rolled command-line parsing: `--name value`, `--name=value`,
/// and boolean `--flag` / `--no-flag`.
struct Arguments {
    enum Failure: Error, CustomStringConvertible, Equatable {
        case missingValue(String)
        case invalidValue(String, String)
        case unknown(String)

        var description: String {
            switch self {
            case .missingValue(let name): "missing value for --\(name)"
            case .invalidValue(let name, let value): "invalid value '\(value)' for --\(name)"
            case .unknown(let name): "unknown argument '\(name)'"
            }
        }
    }

    private var values: [String: String] = [:]
    private var flags: [String: Bool] = [:]
    private var consumed: Set<String> = []
    private(set) var positional: [String] = []

    /// `valueOptions` are names that take a value; every other `--name` is a flag.
    init(_ arguments: [String], valueOptions: Set<String>) throws(Failure) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard argument.hasPrefix("--"), argument.count > 2 else {
                positional.append(argument)
                continue
            }
            var name = String(argument.dropFirst(2))
            var inlineValue: String?
            if let equals = name.firstIndex(of: "=") {
                inlineValue = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            if valueOptions.contains(name) {
                if let inlineValue {
                    values[name] = inlineValue
                } else {
                    guard index < arguments.count else { throw .missingValue(name) }
                    values[name] = arguments[index]
                    index += 1
                }
            } else if inlineValue != nil {
                throw .unknown(argument)
            } else if name.hasPrefix("no-") {
                flags[String(name.dropFirst(3))] = false
            } else {
                flags[name] = true
            }
        }
    }

    mutating func string(_ name: String) -> String? {
        consumed.insert(name)
        return values[name]
    }

    mutating func int(_ name: String) throws(Failure) -> Int? {
        guard let text = string(name) else { return nil }
        guard let value = Int(text), value >= 0 else { throw .invalidValue(name, text) }
        return value
    }

    /// Seconds, accepting a plain number or a number with an `s` / `ms` suffix.
    mutating func seconds(_ name: String) throws(Failure) -> Double? {
        guard let text = string(name) else { return nil }
        var number = Substring(text)
        var scale = 1.0
        if number.hasSuffix("ms") {
            number = number.dropLast(2)
            scale = 0.001
        } else if number.hasSuffix("s") {
            number = number.dropLast()
        }
        guard let value = Double(number), value > 0 else { throw .invalidValue(name, text) }
        return value * scale
    }

    mutating func flag(_ name: String) -> Bool? {
        consumed.insert(name)
        return flags[name]
    }

    /// Throws for any option that was supplied but never read.
    func checkAllConsumed() throws(Failure) {
        for name in values.keys.sorted() where !consumed.contains(name) { throw .unknown("--\(name)") }
        for name in flags.keys.sorted() where !consumed.contains(name) { throw .unknown("--\(name)") }
    }
}
