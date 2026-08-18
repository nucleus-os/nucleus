import Foundation
import Testing

@testable import ColliderCore

@Test
func scrubberRedactsJSONEncodedSecrets() {
    // A control-plane response is the shape a captured command emits, and it
    // reaches the durable run log unless every secret field is redacted.
    #expect(
        CredentialScrubber.text(#"{"token":"AABBCCDD","expires_at":"2026-08-18T03:19:00Z"}"#)
            == #"{"token":"<redacted>","expires_at":"2026-08-18T03:19:00Z"}"#)
    #expect(
        CredentialScrubber.text(#"{"secret" : "AABBCCDD"}"#)
            == #"{"secret" : "<redacted>"}"#)
    #expect(
        CredentialScrubber.text(#"{"api_key":"AABBCCDD","client_id":"public"}"#)
            == #"{"api_key":"<redacted>","client_id":"public"}"#)
    #expect(
        CredentialScrubber.text(#"{"TOKEN":"AABBCCDD"}"#)
            == #"{"TOKEN":"<redacted>"}"#)
    #expect(
        CredentialScrubber.text(#"{"runner":"nucleus-m2-ultra","busy":false}"#)
            == #"{"runner":"nucleus-m2-ultra","busy":false}"#)
}

@Test
func scrubberRedactsFormEncodedSecrets() {
    #expect(
        CredentialScrubber.text("token=AABBCCDD&name=runner")
            == "token=<redacted>&name=runner")
    #expect(
        CredentialScrubber.text("Authorization: Bearer AABBCCDD")
            == "Authorization: <redacted>")
}

@Test
func scrubberRedactsTheValueFollowingASecretArgument() {
    #expect(
        CredentialScrubber.command(["config.sh", "--token", "AABBCCDD", "--name", "runner"])
            == ["config.sh", "--token", "<redacted>", "--name", "runner"])
}
