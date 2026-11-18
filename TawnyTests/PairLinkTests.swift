import XCTest
@testable import Tawny

/// What a pairing link is allowed to do to this phone. The same cases as
/// PairLinkTest.kt in Tawny Android, so both apps read a link the same way.
final class PairLinkTests: XCTestCase {

    private func parse(
        _ raw: String,
        preferredRelayHost: String? = nil,
        buildRelayHost: String? = nil,
        hasRendezvous: Bool = false
    ) -> Pairing? {
        PairLink.parse(raw, preferredRelayHost: preferredRelayHost,
                       buildRelayHost: buildRelayHost, hasRendezvous: hasRendezvous)
    }

    private let webLink = "https://tawny.ainu-anoles.ts.net/#k=GpgOcJxe4H6eAhLZpgZ72w"
        + "&n=Pet+camera&r=viewer&t=NvM7UXwo8X79vagb9VARxQ&c=WXXHeH07nDk&e=1789060818"

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: the reported link

    func testWebMonitorLinkParsesExactlyAsReported() throws {
        let p = try XCTUnwrap(parse(webLink))
        XCTAssertNil(p.signal)
        XCTAssertEqual(p.key, "GpgOcJxe4H6eAhLZpgZ72w")
        XCTAssertEqual(p.name, "Pet camera")
        XCTAssertEqual(p.token, "NvM7UXwo8X79vagb9VARxQ")
        XCTAssertEqual(p.code, "WXXHeH07nDk")
        XCTAssertEqual(p.expiresAt, 1_789_060_818_000)
        XCTAssertEqual(p.relay, "wss://tawny.ainu-anoles.ts.net")
        XCTAssertTrue(p.relayTrusted)
    }

    func testQueryStringOnHttpsLinkIsNeverRead() {
        XCTAssertNil(parse("https://tawny.ainu-anoles.ts.net/?k=GpgOcJxe4H6eAhLZpgZ72w&e=1789060818"))
    }

    // MARK: tawny://

    func testTawnyPairLink() throws {
        let p = try XCTUnwrap(parse("tawny://pair?k=GpgOcJxe4H6eAhLZpgZ72w&h=192.168.1.50:8820"
            + "&t=NvM7UXwo8X79vagb9VARxQ&c=WXXHeH07nDk&e=1789060818"))
        XCTAssertEqual(p.signal, "ws://192.168.1.50:8820")
        XCTAssertEqual(p.key, "GpgOcJxe4H6eAhLZpgZ72w")
        XCTAssertEqual(p.name, "Pet camera")
        XCTAssertEqual(p.token, "NvM7UXwo8X79vagb9VARxQ")
        XCTAssertEqual(p.code, "WXXHeH07nDk")
        XCTAssertEqual(p.expiresAt, 1_789_060_818_000)
        XCTAssertNil(p.relay)
        XCTAssertFalse(p.relayTrusted)
    }

    func testControlAndBidiCharactersAreDroppedFromTheName() {
        let k = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(parse("tawny://pair?k=\(k)&h=192.168.1.20:8080&n=Re%0Dx%0A%E2%80%AEtoR%E2%80%A8%00!")?.name, "RextoR!")
        XCTAssertEqual(parse("tawny://pair?k=\(k)&h=192.168.1.20:8080&n=%0D%E2%80%AE")?.name, "Pet camera")
    }

    func testPublicIPInHIsDroppedNotDialled() throws {
        XCTAssertNil(parse("tawny://pair?k=GpgOcJxe4H6eAhLZpgZ72w&h=8.8.8.8:8820"))
        let p = try XCTUnwrap(parse("tawny://pair?k=GpgOcJxe4H6eAhLZpgZ72w&h=8.8.8.8:8820", hasRendezvous: true))
        XCTAssertNil(p.signal)
    }

    func testEveryPrivateRangeIsAccepted() {
        for h in ["10.0.0.4:8820", "172.16.5.9:8820", "192.168.1.50:8820", "169.254.3.3:8820"] {
            XCTAssertEqual(parse("tawny://pair?k=GpgOcJxe4H6eAhLZpgZ72w&h=\(h)")?.signal, "ws://\(h)")
        }
    }

    func testMalformedKeyIsRefused() {
        XCTAssertNil(parse("tawny://pair?k=short&h=192.168.1.50:8820"))
        XCTAssertNil(parse("tawny://pair?k=has+a+space+in+it+here&h=192.168.1.50:8820"))
        XCTAssertNil(parse("tawny://pair?h=192.168.1.50:8820"))
        XCTAssertNil(parse("https://tawny.ainu-anoles.ts.net/#k=nope"))
    }

    func testMalformedTokenIsRefusedOutright() {
        XCTAssertNil(parse("tawny://pair?k=GpgOcJxe4H6eAhLZpgZ72w&h=192.168.1.50:8820&t=no"))
    }

    func testExpiryInThePastReadsAsExpired() throws {
        var past = try XCTUnwrap(parse(webLink))
        past.expiresAt = 1000
        XCTAssertTrue(past.isExpired())
        var future = try XCTUnwrap(parse(webLink))
        future.expiresAt = nowMs + 600_000
        XCTAssertFalse(future.isExpired())
        let none = try XCTUnwrap(parse("tawny://pair?k=GpgOcJxe4H6eAhLZpgZ72w&h=192.168.1.50:8820"))
        XCTAssertEqual(none.expiresAt, 0)
        XCTAssertFalse(none.isExpired())
    }

    func testViewerClockHoursOffDoesNotCallFreshCodeExpired() throws {
        var skewed = try XCTUnwrap(parse(webLink))
        skewed.expiresAt = nowMs - 2 * 60 * 60 * 1000 + 600_000
        XCTAssertFalse(skewed.isExpired())
        var stale = try XCTUnwrap(parse(webLink))
        stale.expiresAt = nowMs - Pairing.clockSkewMs - 60_000
        XCTAssertTrue(stale.isExpired())
    }

    func testNonsenseIsRefused() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("not a link at all"))
        XCTAssertNil(parse("tawny://notpair?k=GpgOcJxe4H6eAhLZpgZ72w"))
        XCTAssertNil(parse("ftp://example.com/#k=GpgOcJxe4H6eAhLZpgZ72w"))
        XCTAssertNil(parse("https://tawny.ainu-anoles.ts.net/"))
        XCTAssertNil(parse("https://tawny.ainu-anoles.ts.net/#"))
    }

    // MARK: security

    func testStrangersOriginNeverGetsItsHostAdopted() throws {
        let p = try XCTUnwrap(parse("https://evil.example/#k=GpgOcJxe4H6eAhLZpgZ72w&e=1789060818"))
        XCTAssertEqual(p.key, "GpgOcJxe4H6eAhLZpgZ72w")
        XCTAssertEqual(p.relay, "wss://evil.example")
        XCTAssertFalse(p.relayTrusted)
    }

    func testRvPointingAtThirdHostIsIgnored() throws {
        let p = try XCTUnwrap(parse("https://tawny.ainu-anoles.ts.net/#k=GpgOcJxe4H6eAhLZpgZ72w"
            + "&rv=wss%3A%2F%2Fevil.example"))
        XCTAssertEqual(p.relay, "wss://tawny.ainu-anoles.ts.net")
        XCTAssertTrue(p.relayTrusted)
    }

    func testRvNamingTheLinksOwnHostIsHonoured() throws {
        let p = try XCTUnwrap(parse("https://tawny.ainu-anoles.ts.net/#k=GpgOcJxe4H6eAhLZpgZ72w"
            + "&rv=wss%3A%2F%2Ftawny.ainu-anoles.ts.net%3A8443"))
        XCTAssertEqual(p.relay, "wss://tawny.ainu-anoles.ts.net:8443")
        XCTAssertTrue(p.relayTrusted)
    }

    func testUserinfoTrickCannotBorrowATrustedName() throws {
        let p = try XCTUnwrap(parse("https://evil.example/#k=GpgOcJxe4H6eAhLZpgZ72w"
            + "&rv=wss%3A%2F%2Fgood.ts.net%40evil.example"))
        XCTAssertEqual(p.relay, "wss://evil.example")
        XCTAssertFalse(p.relayTrusted)
    }

    func testANameThatMerelyContainsTsNetIsNotATailnetName() {
        XCTAssertFalse(PairLink.relayAdoptable("ts.net.evil.example", nil, nil))
        XCTAssertFalse(PairLink.relayAdoptable("evilts.net", nil, nil))
        XCTAssertFalse(PairLink.relayAdoptable("ts.net", nil, nil))
        XCTAssertTrue(PairLink.relayAdoptable("tawny.ainu-anoles.ts.net", nil, nil))
        XCTAssertTrue(PairLink.relayAdoptable("TAWNY.AINU-ANOLES.TS.NET", nil, nil))
    }

    func testRelayAlreadyInUseIsAnAnchorAndThePortIsPartOfIt() {
        XCTAssertTrue(PairLink.relayAdoptable("relay.example.net", "relay.example.net", nil))
        XCTAssertTrue(PairLink.relayAdoptable("worker.example.dev", nil, "worker.example.dev"))
        XCTAssertTrue(PairLink.relayAdoptable("relay.example.net", "relay.example.net:443", nil))
        XCTAssertTrue(PairLink.relayAdoptable("relay.example.net:443", "relay.example.net", nil))
        XCTAssertTrue(PairLink.relayAdoptable("relay.example.net:8443", "relay.example.net:8443", nil))
        XCTAssertFalse(PairLink.relayAdoptable("relay.example.net:9999", "relay.example.net", nil))
        XCTAssertFalse(PairLink.relayAdoptable("relay.example.net", "relay.example.net:8443", nil))
        XCTAssertFalse(PairLink.relayAdoptable("relay.example.net:8443", "relay.example.net:9999", nil))
        XCTAssertFalse(PairLink.relayAdoptable("relay.example.net:9999", nil, "relay.example.net"))
        XCTAssertFalse(PairLink.relayAdoptable("other.example.net", "relay.example.net", nil))
    }

    func testPortNeverWeakensTheReachabilityAnchors() {
        XCTAssertTrue(PairLink.relayAdoptable("tawny.ainu-anoles.ts.net", nil, nil))
        XCTAssertTrue(PairLink.relayAdoptable("tawny.ainu-anoles.ts.net:8443", nil, nil))
        XCTAssertTrue(PairLink.relayAdoptable("192.168.1.50:8099", nil, nil))
        XCTAssertFalse(PairLink.relayAdoptable("evil.example:443", nil, nil))
    }

    func testPrivateAddressIsTheSameTrustAsH() {
        XCTAssertTrue(PairLink.relayAdoptable("192.168.1.50:8099", nil, nil))
        XCTAssertTrue(PairLink.relayAdoptable("10.1.2.3", nil, nil))
        XCTAssertFalse(PairLink.relayAdoptable("8.8.8.8", nil, nil))
        XCTAssertFalse(PairLink.relayAdoptable("", nil, nil))
        XCTAssertFalse(PairLink.relayAdoptable(nil, nil, nil))
    }

    func testStrangersOriginIsAdoptedOnceTheUserPointedAtIt() throws {
        let p = try XCTUnwrap(parse("https://relay.example.net/#k=GpgOcJxe4H6eAhLZpgZ72w",
                                    preferredRelayHost: "relay.example.net"))
        XCTAssertTrue(p.relayTrusted)
    }

    // MARK: parameter edges

    func testParameterOdditiesDoNotDerailTheParse() throws {
        let p = try XCTUnwrap(parse("tawny://pair?k=GpgOcJxe4H6eAhLZpgZ72w&&r=viewer&h=192.168.1.50:8820&"))
        XCTAssertEqual(p.signal, "ws://192.168.1.50:8820")
        XCTAssertEqual(parse("tawny://pair?k=GpgOcJxe4H6eAhLZpgZ72w&h=192.168.1.50:8820&n=S%C3%A9amus%27%20cat")?.name, "Séamus' cat")
        XCTAssertEqual(parse("tawny://pair?k=GpgOcJxe4H6eAhLZpgZ72w&h=192.168.1.50:8820&n=" + String(repeating: "x", count: 80))?.name.count, 40)
        XCTAssertEqual(parse("tawny://pair?k=GpgOcJxe4H6eAhLZpgZ72w&h=192.168.1.50:8820&n=")?.name, "Pet camera")
        XCTAssertEqual(parse("tawny://pair?k=GpgOcJxe4H6eAhLZpgZ72w&h=192.168.1.50:8820&h=10.0.0.9:8820")?.signal, "ws://192.168.1.50:8820")
        XCTAssertNil(try XCTUnwrap(parse("tawny://pair?k=GpgOcJxe4H6eAhLZpgZ72w&h=192.168.1.50:8820&c=nope")).code)
        XCTAssertEqual(parse("tawny://pair?k=GpgOcJxe4H6eAhLZpgZ72w&h=192.168.1.50:8820&n=100%25+cat")?.name, "100% cat")
    }

    func testExplicitPortOnAWebLinkIsCarriedIntoTheRelay() throws {
        let p = try XCTUnwrap(parse("https://tawny.ainu-anoles.ts.net:8443/#k=GpgOcJxe4H6eAhLZpgZ72w"))
        XCTAssertEqual(p.relay, "wss://tawny.ainu-anoles.ts.net:8443")
    }

    func testNpIsReadFromAnAppLinkAndFromAWebLink() {
        let np = String(repeating: "a", count: 63) + "1"
        XCTAssertEqual(parse("tawny://pair?k=abcdefghijklmnop1234&n=Cam&h=192.168.1.20:8443&c=abcdefgh&np=\(np)")?.nostrStation, np)
        XCTAssertEqual(parse("https://tawny.example.ts.net/#k=abcdefghijklmnop1234&n=Cam&r=viewer&c=abcdefgh&np=\(np)")?.nostrStation, np)
    }

    func testNpInCapitalsIsTakenAsTheSameKey() {
        let np = String(repeating: "AB", count: 32)
        XCTAssertEqual(parse("tawny://pair?k=abcdefghijklmnop1234&h=192.168.1.20:8443&np=\(np)")?.nostrStation, np.lowercased())
    }

    func testLinkWithoutNpOrWithMalformedOneStillPairs() {
        let none = parse("tawny://pair?k=abcdefghijklmnop1234&h=192.168.1.20:8443")
        XCTAssertNotNil(none)
        XCTAssertNil(none?.nostrStation)
        for bad in ["abc", String(repeating: "g", count: 64), String(repeating: "a", count: 65), String(repeating: "a", count: 63) + "%22"] {
            let p = parse("tawny://pair?k=abcdefghijklmnop1234&h=192.168.1.20:8443&np=\(bad)")
            XCTAssertNotNil(p, "still a pairing: \(bad)")
            XCTAssertNil(p?.nostrStation, "np refused: \(bad)")
        }
    }

    // MARK: the link this iPhone's Monitor hands out

    func testOwnPairingPayloadRoundTrips() throws {
        let link = pairingPayload(key: "GpgOcJxe4H6eAhLZpgZ72w", name: "Miso & Pickle", token: "NvM7UXwo8X79vagb9VARxQ",
                                  code: "WXXHeH07nDk", expiresAtMs: 1_789_060_818_000, nostrPub: String(repeating: "c", count: 64))
        let p = try XCTUnwrap(parse(link, hasRendezvous: true))
        XCTAssertEqual(p.key, "GpgOcJxe4H6eAhLZpgZ72w")
        XCTAssertEqual(p.name, "Miso & Pickle")
        XCTAssertEqual(p.token, "NvM7UXwo8X79vagb9VARxQ")
        XCTAssertEqual(p.code, "WXXHeH07nDk")
        XCTAssertEqual(p.expiresAt, 1_789_060_818_000)
        XCTAssertEqual(p.nostrStation, String(repeating: "c", count: 64))
        XCTAssertNil(p.signal)
    }

    func testRandTokensFitTheKeyAndCodeShapes() throws {
        XCTAssertNotNil(parse("tawny://pair?k=\(randToken(16))&c=\(randToken(8))", hasRendezvous: true)?.code)
    }
}
