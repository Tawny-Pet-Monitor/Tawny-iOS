import XCTest
@testable import Tawny

/// The diagnostics log is the one a user may choose to share. The privacy
/// policy says it holds hashed room identifiers and connection events, never
/// a key or an IP address. The same cases as DiagRedactTest.kt in Tawny
/// Android, so both apps cut a line the same way.
final class DiagRedactTests: XCTestCase {
    private func r(_ s: String) -> String { Diag.redact(s) }

    func testAddressesAreMasked() {
        XCTAssertEqual(r("dial lan 192.168.1.34:43377 room=ab12cd34ef56ab78"),
                       "dial lan <lan-ip>:43377 room=ab12cd34ef56ab78")
        XCTAssertEqual(r("stun answer 8.8.8.8"), "stun answer <ip>")
        XCTAssertEqual(r("page at 127.0.0.1:8809"), "page at 127.0.0.1:8809")
    }

    func testTheHashedRoomIdStays() {
        XCTAssertEqual(r("cloud welcome room=9f3a1c0de4b5a6c7 peers=1"),
                       "cloud welcome room=9f3a1c0de4b5a6c7 peers=1")
    }

    func testPeerIdsAndKeysGo() {
        XCTAssertEqual(r("call with 3f9c2a7be41d: Disconnected"), "call with <id>: Disconnected")
        XCTAssertEqual(r("nostr: viewer c3400f6e went quiet"), "nostr: viewer <id> went quiet")
        XCTAssertEqual(
            r("offer refused from 0827bcca44acada87864ff90d708e3913cf3bb6f42aae07f58cb2c5eaf03e510: unsigned"),
            "offer refused from <id>: unsigned")
    }

    func testNumbersAndCodesStay() {
        XCTAssertEqual(r("camera 960x540: 20.0 fps in"), "camera 960x540: 20.0 fps in")
        XCTAssertEqual(r("pairing code rotated — 600s"), "pairing code rotated — 600s")
        XCTAssertEqual(r("expires 1795454097"), "expires 1795454097")
    }

    func testLinkSecretsGo() {
        let out = r("adopt https://x.example/#k=Zx9_-abcDEF0123456789&n=Pet&t=NvM7UXwo8X79&c=WXXHeH07nDk&np=e8a05f74890e")
        for secret in ["Zx9_", "NvM7", "WXXH", "e8a05f", "Pet"] {
            XCTAssertFalse(out.contains(secret), out)
        }
    }

    func testNamesGo() {
        XCTAssertEqual(r("pair accepted name=\"Mochi\" lan=- relay=-"),
                       "pair accepted name=<name> lan=- relay=-")
        XCTAssertEqual(r(#"control: {"type":"meta","name":"Pp","from":"c3400f6e8186"}"#),
                       #"control: {"type":"meta","name":"<name>","from":"<id>"}"#)
    }

    func testQuotedNamesGoWhole() {
        XCTAssertEqual(r(#"pair accepted name="Lou\"s cat" lan=-"#), "pair accepted name=<name> lan=-")
        XCTAssertEqual(r(#"{"name":"Mo\"chi Bear","x":1}"#), #"{"name":"<name>","x":1}"#)
    }

    func testUUIDsAndUppercaseIdsGo() {
        XCTAssertEqual(r("bond 3f9c2a7b-e41d-4a2b-9c1e-0123456789ab ok"), "bond <id> ok")
        XCTAssertEqual(r("peer 3F9C2A7BE41D left"), "peer <id> left")
    }

    func testHomeAndTailnetHostsGo() {
        XCTAssertEqual(r("relay=wss://tawny.ainu-anoles.ts.net:8443/ up"), "relay=wss://<private-host>:8443/ up")
        XCTAssertEqual(r("lan=ws://lous-mac.local:8080"), "lan=ws://<private-host>:8080")
        XCTAssertEqual(r("relay=wss://relay.damus.io"), "relay=wss://relay.damus.io")
    }
}
