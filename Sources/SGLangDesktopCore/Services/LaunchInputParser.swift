import Foundation

public enum LaunchInputParser {
    /// Tokenizes user-provided arguments without invoking a shell.
    ///
    /// Single/double quotes group whitespace and backslash escapes the next
    /// character. Shell expansion, command substitution, globbing, and pipes
    /// are deliberately not implemented.
    public static func arguments(from input: String) throws -> [String] {
        enum Quote {
            case single
            case double
        }

        var result: [String] = []
        var current = ""
        var quote: Quote?
        var escaping = false
        var tokenStarted = false

        for character in input {
            if escaping {
                current.append(character)
                tokenStarted = true
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                tokenStarted = true
                continue
            }
            switch quote {
            case .single:
                if character == "'" {
                    quote = nil
                } else {
                    current.append(character)
                }
                tokenStarted = true
            case .double:
                if character == "\"" {
                    quote = nil
                } else {
                    current.append(character)
                }
                tokenStarted = true
            case nil:
                if character == "'" {
                    quote = .single
                    tokenStarted = true
                } else if character == "\"" {
                    quote = .double
                    tokenStarted = true
                } else if character.isWhitespace {
                    if tokenStarted {
                        result.append(current)
                        current = ""
                        tokenStarted = false
                    }
                } else {
                    current.append(character)
                    tokenStarted = true
                }
            }
        }

        guard !escaping else { throw LaunchInputError.trailingEscape }
        guard quote == nil else { throw LaunchInputError.unterminatedQuote }
        if tokenStarted { result.append(current) }
        return result
    }

    public static func environment(from input: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for (offset, rawLine) in input.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: "=") else {
                throw LaunchInputError.invalidEnvironmentLine(offset + 1)
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
            guard isValidEnvironmentKey(key) else {
                throw LaunchInputError.invalidEnvironmentKey(key, line: offset + 1)
            }
            let upper = key.uppercased()
            let protectedExact: Set<String> = [
                "HOME", "TMPDIR", "PATH", "SHELL", "VIRTUAL_ENV", "SGLANG_CACHE_DIR",
                "HF_HOME", "SGLANG_USE_MLX", "SGLANG_OMNI_STRICT_PORT",
            ]
            let protectedPrefixes = ["PYTHON", "CONDA_", "UV_", "DYLD_", "LD_"]
            guard !protectedExact.contains(upper),
                !protectedPrefixes.contains(where: { upper.hasPrefix($0) })
            else {
                throw LaunchInputError.protectedEnvironmentKey(key, line: offset + 1)
            }
            let secretMarkers = ["TOKEN", "KEY", "SECRET", "PASSWORD"]
            guard !secretMarkers.contains(where: { upper.contains($0) }) else {
                throw LaunchInputError.secretEnvironmentKey(key, line: offset + 1)
            }
            result[key] = value
        }
        return result
    }

    public static func shellEscapedPreview(_ values: [String]) -> String {
        values.map { value in
            if value.isEmpty { return "''" }
            let safe = value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:=@+")).contains(
                    $0)
            }
            if safe { return value }
            return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
        }.joined(separator: " ")
    }

    private static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.first, first == "_" || first.isLetter else { return false }
        return key.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}

public enum LaunchInputError: LocalizedError, Equatable {
    case unterminatedQuote
    case trailingEscape
    case invalidEnvironmentLine(Int)
    case invalidEnvironmentKey(String, line: Int)
    case protectedEnvironmentKey(String, line: Int)
    case secretEnvironmentKey(String, line: Int)

    public var errorDescription: String? {
        switch self {
        case .unterminatedQuote:
            "Extra arguments contain an unterminated quote."
        case .trailingEscape:
            "Extra arguments end with an incomplete escape."
        case .invalidEnvironmentLine(let line):
            "Environment line \(line) must use KEY=VALUE."
        case .invalidEnvironmentKey(let key, let line):
            "Environment key \(key) on line \(line) is invalid."
        case .protectedEnvironmentKey(let key, let line):
            "Environment key \(key) on line \(line) is managed by SGLang Desktop."
        case .secretEnvironmentKey(let key, let line):
            "Environment key \(key) on line \(line) looks secret and must be stored in Keychain."
        }
    }
}
