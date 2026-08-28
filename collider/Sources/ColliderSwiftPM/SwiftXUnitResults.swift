import ColliderCore
import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

enum SwiftXUnitResults {
    static func decode(_ bytes: [UInt8]) throws -> [TestCaseObservation] {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: Data(bytes))
        // XMLParser keeps this reference unowned; the local strong reference
        // outlives the synchronous parse below.
        #if canImport(Darwin)
        unsafe parser.delegate = delegate
        #else
        parser.delegate = delegate
        #endif
        guard parser.parse() else {
            throw SwiftXUnitResultsFailure.invalidXML(
                parser.parserError.map(String.init(describing:)) ?? "unknown parser error")
        }
        return delegate.results
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        private struct Pending {
            let suite: String?
            let name: String
            let durationNanoseconds: UInt64
            var outcome: TestCaseObservation.Outcome = .passed
        }

        var results: [TestCaseObservation] = []
        private var pending: Pending?

        func parser(
            _: XMLParser,
            didStartElement elementName: String,
            namespaceURI _: String?,
            qualifiedName _: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "testcase":
                guard let name = attributeDict["name"], !name.isEmpty else { return }
                let seconds = Double(attributeDict["time"] ?? "0") ?? 0
                let nanoseconds =
                    seconds.isFinite && seconds > 0
                    ? UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
                    : 0
                pending = Pending(
                    suite: attributeDict["classname"],
                    name: name,
                    durationNanoseconds: nanoseconds)
            case "failure", "error":
                pending?.outcome = .failed
            case "skipped":
                pending?.outcome = .skipped
            default:
                break
            }
        }

        func parser(
            _: XMLParser,
            didEndElement elementName: String,
            namespaceURI _: String?,
            qualifiedName _: String?
        ) {
            guard elementName == "testcase", let pending else { return }
            results.append(
                TestCaseObservation(
                    suite: pending.suite,
                    name: pending.name,
                    durationNanoseconds: pending.durationNanoseconds,
                    outcome: pending.outcome))
            self.pending = nil
        }
    }
}

enum SwiftXUnitResultsFailure: Error, CustomStringConvertible {
    case invalidXML(String)

    var description: String {
        switch self {
        case .invalidXML(let reason): "invalid Swift test xUnit output: \(reason)"
        }
    }
}
