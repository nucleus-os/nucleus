import Foundation

public enum CredentialScrubber {
    private static let sensitiveNames = [
        "authorization", "cookie", "credential", "password", "passwd",
        "secret", "token", "api-key", "api_key", "apikey", "access-key",
        "access_key",
    ]

    public static func command(_ arguments: [String]) -> [String] {
        var redactNext = false
        return arguments.map { argument in
            if redactNext {
                redactNext = false
                return "<redacted>"
            }
            let normalized = argument
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                .lowercased()
            if sensitiveNames.contains(normalized) {
                redactNext = true
                return argument
            }
            return text(argument)
        }
    }

    public static func text(_ value: String) -> String {
        var result = redactURLIfPresent(value)
        for pattern in [
            #"(?i)(authorization\s*:\s*)[^\r\n]+"#,
            #"(?i)(cookie\s*:\s*)[^\r\n]+"#,
            #"(?i)((?:credential|password|passwd|secret|token|api[-_]?key|access[-_]?key)=)[^\s&]+"#,
        ] {
            result = result.replacingOccurrences(
                of: pattern,
                with: "$1<redacted>",
                options: .regularExpression)
        }
        return result
    }

    public static func bytes(_ value: [UInt8]) -> [UInt8] {
        let decoded = String(decoding: value, as: UTF8.self)
        let redacted = text(decoded)
        return redacted == decoded ? value : Array(redacted.utf8)
    }

    public static func url(_ value: URL) -> URL {
        guard var components = URLComponents(
            url: value, resolvingAgainstBaseURL: false)
        else { return value }
        if components.user != nil { components.user = "<redacted>" }
        if components.password != nil { components.password = "<redacted>" }
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.map { item in
                guard sensitiveNames.contains(item.name.lowercased()) else {
                    return item
                }
                return URLQueryItem(name: item.name, value: "<redacted>")
            }
        }
        return components.url ?? value
    }

    private static func redactURLIfPresent(_ value: String) -> String {
        guard value.contains("://") else { return value }
        return value.split(
            separator: " ",
            omittingEmptySubsequences: false
        ).map { field in
            guard let candidate = URL(string: String(field)),
                  candidate.scheme != nil
            else { return String(field) }
            return url(candidate).absoluteString
        }.joined(separator: " ")
    }
}
