import CxxStdlib
import Foundation
import FoundationNetworking
import FoundationXML

@main
struct Hello {
    static func main() {
        let url = URL(string: "https://example.com")!
        let parser = XMLParser(data: Data("<nucleus/>".utf8))
        precondition(parser.parse())
        let cxxString = std.string("nucleus")
        precondition(cxxString.size() == 7)
        print(url.host ?? "missing-host")
    }
}
