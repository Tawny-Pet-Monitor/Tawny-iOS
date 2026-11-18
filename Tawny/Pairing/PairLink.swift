import Foundation

/// What a pairing link says, once it has been read and vetted.
///
/// A port of `PairLink.kt` in Tawny Android, rule for rule: everything a
/// stranger's QR code is allowed to decide about this phone is decided here,
/// and TawnyTests/PairLinkTests.swift holds the same cases as the Android
/// suite so the two platforms cannot drift apart.
struct Pairing: Equatable, Identifiable {
    /// `ws://<lan-ip>:<port>` from `h=`, or nil for a relay-only pairing.
    var signal: String?
    var key: String
    var name: String
    var token: String?
    /// The pairing code from `c`, presented to the Monitor to be let in.
    var code: String?
    /// `e` in epoch milliseconds, or 0 when the code carried no deadline.
    var expiresAt: Int64
    /// The rendezvous the far end is on, when the link carried one (a web
    /// Monitor's `https://<host>/#…`). nil for a plain `tawny://pair` link.
    var relay: String?
    /// Whether [relay] may be used without asking. See `PairLink.relayAdoptable`.
    var relayTrusted: Bool = false
    /// The Monitor's Nostr public key from `np` (64 lowercase hex), if any.
    var nostrStation: String?

    var id: String { key + (code ?? "") }

    /// A wrong timezone on a local-time clock is at most ~14 h off.
    static let clockSkewMs: Int64 = 24 * 60 * 60 * 1000

    /// Stale past any plausible clock disagreement. `expiresAt` was written
    /// by the Monitor's clock and this reads the phone's own; anything closer
    /// goes to the Monitor, which refuses a lapsed code itself.
    func isExpired(now: Date = Date()) -> Bool {
        expiresAt > 0 && Int64(now.timeIntervalSince1970 * 1000) > expiresAt + Pairing.clockSkewMs
    }
}

/// Reading a pairing link. Two dialects arrive here: the apps' own
/// `tawny://pair?…` with the parameters in the query, and a web Monitor's
/// `https://<host>/#k=…` with them in the fragment, which never reaches a
/// server log. A query string on an http(s) link is that same secret in the
/// logged shape, and is deliberately never read.
enum PairLink {
    private static let keyRE = "^[A-Za-z0-9_-]{16,64}$"
    private static let tokenRE = "^[A-Za-z0-9_-]{8,64}$"
    private static let codeRE = "^[A-Za-z0-9_-]{8,32}$"
    private static let nostrPubRE = "^[0-9a-f]{64}$"
    private static let hostPortRE = "^[0-9]{1,3}(\\.[0-9]{1,3}){3}:[0-9]{2,5}$"

    static let defaultName = "Pet camera"

    /// Split a raw link with Foundation's URL parser, then apply the rules.
    static func parse(
        _ raw: String,
        preferredRelayHost: String?,
        buildRelayHost: String?,
        hasRendezvous: Bool
    ) -> Pairing? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let c = URLComponents(string: trimmed) else { return nil }
        return parse(
            scheme: c.scheme?.lowercased(),
            host: c.host,
            port: c.port ?? -1,
            encodedQuery: c.percentEncodedQuery,
            encodedFragment: c.percentEncodedFragment,
            preferredRelayHost: preferredRelayHost,
            buildRelayHost: buildRelayHost,
            hasRendezvous: hasRendezvous
        )
    }

    static func parse(
        scheme: String?,
        host: String?,
        port: Int,
        encodedQuery: String?,
        encodedFragment: String?,
        preferredRelayHost: String?,
        buildRelayHost: String?,
        hasRendezvous: Bool
    ) -> Pairing? {
        let isWeb = scheme == "https" || scheme == "http"
        let paramSrc: String
        if scheme == "tawny" && host == "pair" {
            paramSrc = encodedQuery ?? ""
        } else if isWeb, let f = encodedFragment, !f.isEmpty {
            paramSrc = f
        } else {
            return nil
        }
        let q = params(paramSrc)
        guard let key = q["k"], matches(key, keyRE) else { return nil }

        var h = q["h"]
        if let hp = h, !matches(hp, hostPortRE) || !isPrivateHostPort(hp) {
            h = nil   // a public IP in a pairing link is not something we dial
        }
        let token = q["t"]
        if let token, !matches(token, tokenRE) { return nil }

        // Where the far end can be met. On a web link its own origin is the
        // relay unless `rv=` names another, and `rv=` is honoured only when it
        // is the link's own host or a rendezvous this install already uses.
        let linkHost: String? = isWeb ? host.flatMap { $0.isEmpty ? nil : $0 } : nil
        var relayHostPort: String? = linkHost.map { $0 + (port > 0 ? ":\(port)" : "") }
        if let rv = q["rv"], !rv.trimmingCharacters(in: .whitespaces).isEmpty {
            if let r = splitRelay(rv) {
                let rHost = before(r, ":")
                if sameHost(rHost, linkHost) {
                    relayHostPort = r
                } else if sameHost(rHost, preferredRelayHost.map { before($0, ":") })
                            || sameHost(rHost, buildRelayHost.map { before($0, ":") }) {
                    relayHostPort = r
                }
                // An rv= pointing anywhere else is simply ignored.
            }
        }
        let relay = relayHostPort.map { "wss://\($0)" }

        // Nothing named at all: no LAN address, no relay, and no rendezvous.
        if h == nil && relay == nil && !hasRendezvous { return nil }
        let trusted = relay != nil && relayAdoptable(relayHostPort, preferredRelayHost, buildRelayHost)

        // Control characters and bidi overrides can make the "Connect to …?"
        // dialog read as something other than what it is.
        var name = PairLink.defaultName
        if let n = q["n"] {
            let cleaned = String(String.UnicodeScalarView(n.unicodeScalars.filter { !nameUnsafe($0) }))
            if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = String(cleaned.prefix(40))
            }
        }
        let code = q["c"].flatMap { matches($0, codeRE) ? $0 : nil }
        let exp = q["e"].flatMap { Int64($0) }.flatMap { $0 > 0 ? $0 * 1000 : nil } ?? 0
        let np = q["np"].map { $0.lowercased() }.flatMap { matches($0, nostrPubRE) ? $0 : nil }
        return Pairing(
            signal: h.map { "ws://\($0)" }, key: key, name: name, token: token, code: code,
            expiresAt: exp, relay: relay, relayTrusted: trusted, nostrStation: np)
    }

    /// May a relay named by a link be used without anyone being asked?
    /// `*.ts.net` (resolves only inside that tailnet), a private IPv4 address
    /// (the same trust as `h=`), or a relay this install already uses, with
    /// the port as part of its identity.
    static func relayAdoptable(_ hostPort: String?, _ preferredRelayHost: String?, _ buildRelayHost: String?) -> Bool {
        guard let hostPort else { return false }
        let h = before(hostPort, ":").lowercased()
        if h.isEmpty { return false }
        if h.hasSuffix(".ts.net") { return true }
        if isPrivateIPv4(h) { return true }
        return sameEndpoint(hostPort, preferredRelayHost) || sameEndpoint(hostPort, buildRelayHost)
    }

    /// RFC1918 / link-local only: `h` in a pairing link is a home-LAN address.
    static func isPrivateHostPort(_ hostPort: String) -> Bool {
        guard let i = hostPort.lastIndex(of: ":") else { return isPrivateIPv4(hostPort) }
        return isPrivateIPv4(String(hostPort[..<i]))
    }

    // MARK: - helpers

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        // `$` in ICU also matches before a trailing newline, so a decoded
        // value ending in %0A would slip through. Refuse any line break first.
        if s.contains(where: { $0.isNewline }) { return false }
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    /// Control characters, line/paragraph separators, bidi overrides/isolates.
    private static func nameUnsafe(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        return v <= 0x1F || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029
            || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
    }

    private static func before(_ s: String, _ c: Character) -> String {
        guard let i = s.firstIndex(of: c) else { return s }
        return String(s[..<i])
    }

    private static func sameHost(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return a.lowercased() == b.lowercased()
    }

    /// Same host and same port, an absent port meaning 443.
    private static func sameEndpoint(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        let ah = before(a, ":").lowercased(), bh = before(b, ":").lowercased()
        guard !ah.isEmpty, ah == bh else { return false }
        return port(a) == port(b)
    }

    private static func port(_ hostPort: String) -> Int {
        guard let i = hostPort.firstIndex(of: ":") else { return 443 }
        if let p = Int(hostPort[hostPort.index(after: i)...]), (1...65535).contains(p) { return p }
        return 443
    }

    /// `https://h[:p]` or `wss://h[:p]` from an `rv=`, reduced to `h[:p]`.
    private static func splitRelay(_ rv: String) -> String? {
        guard let r = rv.range(of: "://") else { return nil }
        let scheme = rv[..<r.lowerBound].lowercased()
        guard scheme == "https" || scheme == "wss" else { return nil }
        var hostPort = String(rv[r.upperBound...])
        for c: Character in ["/", "?", "#"] { hostPort = before(hostPort, c) }
        // No userinfo: `wss://good.ts.net@evil.example` is evil.example.
        if hostPort.isEmpty || hostPort.contains("@") { return nil }
        return hostPort
    }

    private static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var o: [Int] = []
        for p in parts {
            guard let v = Int(p), (0...255).contains(v), p.allSatisfy(\.isASCII) else { return false }
            o.append(v)
        }
        return o[0] == 10
            || (o[0] == 172 && (16...31).contains(o[1]))
            || (o[0] == 192 && o[1] == 168)
            || (o[0] == 169 && o[1] == 254)
    }

    /// `a=1&b=2` to a map, first occurrence winning; `+` decodes to a space.
    private static func params(_ src: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in src.split(separator: "&", omittingEmptySubsequences: true) {
            let s = String(part)
            let name: String, value: String
            if let eq = s.firstIndex(of: "=") {
                name = decode(String(s[..<eq]))
                value = decode(String(s[s.index(after: eq)...]))
            } else {
                name = decode(s)
                value = ""
            }
            if name.isEmpty || out[name] != nil { continue }
            out[name] = value
        }
        return out
    }

    /// Percent-decoding that keeps a stray or truncated `%` as itself, as
    /// android.net.Uri does, rather than failing the whole link.
    private static func decode(_ s: String) -> String {
        if !s.contains("%") && !s.contains("+") { return s }
        let u = Array(s.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(u.count)
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == UInt8(ascii: "+") {
                bytes.append(UInt8(ascii: " ")); i += 1
            } else if c == UInt8(ascii: "%"), i + 2 < u.count,
                      let hi = hex(u[i + 1]), let lo = hex(u[i + 2]) {
                bytes.append(hi << 4 | lo); i += 3
            } else {
                bytes.append(c); i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

/// The link a Monitor's QR carries:
/// `tawny://pair?k=&n=&t=<ticket>&c=<code>&e=<unix seconds>&np=<nostr pub>`.
/// No `h=`: this iPhone runs no LAN relay, so a Viewer meets it through the
/// rendezvous and the Nostr relays (the media still goes direct on Wi-Fi).
func pairingPayload(key: String, name: String, token: String?, code: String, expiresAtMs: Int64, nostrPub: String?) -> String {
    var s = "tawny://pair?k=\(uriEncode(key))&n=\(uriEncode(name))"
    if let token { s += "&t=\(uriEncode(token))" }
    s += "&c=\(uriEncode(code))&e=\(expiresAtMs / 1000)"
    if let nostrPub { s += "&np=\(nostrPub)" }
    return s
}

/// android.net.Uri.encode: everything but ASCII letters, digits and `-_.!~*'()`.
private func uriEncode(_ s: String) -> String {
    let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}
