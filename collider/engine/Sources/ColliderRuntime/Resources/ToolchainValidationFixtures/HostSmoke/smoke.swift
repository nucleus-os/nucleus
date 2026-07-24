import Foundation
import FoundationXML

@main
struct NucleusToolchainSmoke {
    static func main() {
        let parser = XMLParser(data: Data("<nucleus/>".utf8))
        precondition(parser.parse())
    }
}
