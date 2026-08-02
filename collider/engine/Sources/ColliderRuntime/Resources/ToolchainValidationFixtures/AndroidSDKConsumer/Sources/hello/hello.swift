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
        var cxxString = std.string()
        for character: CChar in [110, 117, 99, 108, 101, 117, 115] {
            cxxString.push_back(character)
        }
        precondition(cxxString.size() == 7)
        print(url.host ?? "missing-host")
    }
}
