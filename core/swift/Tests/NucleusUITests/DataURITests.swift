import Testing
@testable import NucleusUI

/// `data:` URIs, which applications put in icon fields where a path is expected.
@Suite struct DataURITests {
    @Test func aBase64URIDecodesToItsBytes() {
        // "Hi!" — short enough to check by hand.
        let uri = DataURI.parse("data:image/png;base64,SGkh")
        #expect(uri?.mediaType == "image/png")
        #expect(uri?.bytes == Array("Hi!".utf8))
    }

    /// Hand-assembled URIs drop padding, and every other consumer accepts them.
    @Test func missingPaddingIsTolerated() {
        #expect(DataURI.parse("data:;base64,SGk")?.bytes == Array("Hi".utf8))
        #expect(DataURI.parse("data:;base64,SGk=")?.bytes == Array("Hi".utf8))
    }

    /// Line-wrapped base64 is ordinary in files and configuration.
    @Test func embeddedWhitespaceIsIgnored() {
        #expect(DataURI.parse("data:;base64,SG\n kh")?.bytes == Array("Hi!".utf8))
    }

    @Test func percentEncodingDecodes() {
        let uri = DataURI.parse("data:image/svg+xml,%3Csvg%2F%3E")
        #expect(uri?.mediaType == "image/svg+xml")
        #expect(uri?.bytes == Array("<svg/>".utf8))
    }

    @Test func plainTextNeedsNoDecoding() {
        #expect(DataURI.parse("data:,hello")?.bytes == Array("hello".utf8))
    }

    @Test func anEmptyMediaTypeIsAllowed() {
        #expect(DataURI.parse("data:,x")?.mediaType == "")
    }

    // MARK: - Rejection

    /// A path is not a URI, and must fall through to the file path rather than
    /// being parsed into nonsense.
    @Test func anOrdinaryPathIsNotADataURI() {
        #expect(DataURI.parse("/usr/share/icons/hicolor/48x48/apps/firefox.png") == nil)
        #expect(DataURI.parse("firefox") == nil)
        #expect(DataURI.parse("") == nil)
    }

    /// Without a comma there is no payload, only a header.
    @Test func aURIWithoutACommaIsRejected() {
        #expect(DataURI.parse("data:image/png;base64") == nil)
    }

    @Test func invalidBase64IsRejected() {
        #expect(DataURI.parse("data:;base64,not valid base64!!") == nil)
    }

    @Test func aTruncatedPercentEscapeIsRejected() {
        #expect(DataURI.parse("data:,%4") == nil)
        #expect(DataURI.parse("data:,%zz") == nil)
    }

    /// The media type is parsed but not trusted — the decoder sniffs content, so
    /// a mislabelled payload still decodes and a correctly-labelled one still
    /// fails if the bytes are garbage.
    @Test func theMediaTypeIsNotEnforced() {
        let uri = DataURI.parse("data:text/plain;base64,SGkh")
        #expect(uri?.bytes == Array("Hi!".utf8), "payload decodes regardless of label")
    }
}
