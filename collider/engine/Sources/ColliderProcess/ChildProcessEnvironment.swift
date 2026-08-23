import Subprocess

/// The environment a child process may be given.
///
/// `Subprocess.Environment.Key(rawValue:)` accepts any string, so a name
/// carrying a NUL or an `=` reaches the child as a corrupted entry rather than
/// as an error, and a name beginning with a digit is not a portable variable
/// name. Both of Collider's execution paths hand the same kind of dictionary
/// to the same API, so the rules live here once: two copies of a rule that
/// decides what a child is allowed to inherit would eventually disagree.
public enum ChildProcessEnvironment {
    public enum Failure: Error, CustomStringConvertible {
        case invalidName(String)
        case invalidValue(name: String)

        public var description: String {
            switch self {
            case .invalidName(let name):
                "child process environment name is not usable: \(name)"
            case .invalidValue(let name):
                "child process environment value is not usable: \(name)"
            }
        }
    }

    public static func validated(
        _ environment: [String: String]
    ) throws -> [Subprocess.Environment.Key: String] {
        var validated: [Subprocess.Environment.Key: String] = [:]
        for (name, value) in environment {
            guard !name.utf8.contains(0), !name.contains("="),
                name.utf8.first.map({ !(48...57).contains($0) }) ?? true,
                let key = Subprocess.Environment.Key(rawValue: name)
            else {
                throw Failure.invalidName(name)
            }
            guard !value.utf8.contains(0) else {
                throw Failure.invalidValue(name: name)
            }
            validated[key] = value
        }
        return validated
    }
}
