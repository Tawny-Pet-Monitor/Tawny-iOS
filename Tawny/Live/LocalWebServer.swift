import Foundation
import Network

/// Serves the bundled web app on 127.0.0.1, so the web view loads a real
/// secure-context origin (getUserMedia is allowed on http://127.0.0.1, not on
/// a custom URL scheme) with no address to type. GET only, loopback only, a
/// few dozen small files. The port of AssetHttpServer in Tawny Android's
/// LocalWeb.kt, with the same Content-Security-Policy.
///
/// The port is kept stable (8809 first): the page keeps its channels and the
/// Monitor's Nostr key in localStorage, which belongs to the origin, and the
/// origin includes the port.
final class LocalWebServer: @unchecked Sendable {
    static let shared = LocalWebServer()

    private let queue = DispatchQueue(label: "tawny.http")
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var lanRelay: String?
    private var relayHosts: [String] = []
    private let root: URL? = Bundle.main.url(forResource: "Web", withExtension: nil)

    private static let maxHead = 16 * 1024
    private static let connectSrcToken = "__TAWNY_CONNECT_SRC__"
    private static let lanWS = #"^ws://[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{1,5}$"#

    /// The relays this session's page may reach, named in its CSP. Call before
    /// pointing the web view here: the policy travels with the page.
    func configure(lanRelay: String?, relayHosts: [String]) {
        lock.withLock {
            self.lanRelay = lanRelay.flatMap { $0.range(of: Self.lanWS, options: .regularExpression) != nil ? $0 : nil }
            self.relayHosts = relayHosts
        }
    }

    /// Starts the server if it is not already listening. Returns the port.
    func start() async -> UInt16? {
        if let port = lock.withLock({ listener != nil && boundPort != 0 ? boundPort : nil }) { return port }
        for port in UInt16(8809)...UInt16(8833) {
            if await bind(port) { return port }
        }
        Diag.post("http", "no free loopback port in 8809-8833")
        return nil
    }

    private func bind(_ port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return false }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = Once()
            l.stateUpdateHandler = { [weak self] state in
                // Always called on `queue`, one at a time.
                switch state {
                case .ready:
                    if once.claim() {
                        self?.lock.withLock { self?.listener = l; self?.boundPort = port }
                        Diag.post("http", "serving on 127.0.0.1:\(port)")
                        cont.resume(returning: true)
                    }
                case .failed(let err), .waiting(let err):
                    if once.claim() {
                        l.cancel()
                        cont.resume(returning: false)
                    } else {
                        // It was serving and died (the app was suspended for a
                        // long time): forget it, so the next start() rebinds.
                        Diag.post("http", "listener lost: \(err)")
                        self?.lock.withLock {
                            if self?.listener === l { self?.listener = nil; self?.boundPort = 0 }
                        }
                        l.cancel()
                    }
                case .cancelled:
                    if once.claim() { cont.resume(returning: false) }
                default:
                    break
                }
            }
            l.start(queue: queue)
        }
    }

    // MARK: connections

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        // A caller that never finishes its request does not get to hold on.
        queue.asyncAfter(deadline: .now() + 5) { c.cancel() }
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHead) { [weak self] data, _, done, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(c, head: buf.subdata(in: buf.startIndex..<end.lowerBound))
            } else if buf.count > Self.maxHead || done || error != nil {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, head: Data) {
        let text = String(decoding: head, as: UTF8.self)
        let requestLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            return send(c, 405, "text/plain", Data("method not allowed".utf8))
        }
        let rawPath = String(parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        var path = rawPath.removingPercentEncoding ?? rawPath
        if path.isEmpty || path == "/" { path = "/index.html" }

        guard let rel = Self.resolve(path), let root else {
            return send(c, 403, "text/plain", Data("forbidden".utf8))
        }
        let file = root.appendingPathComponent(rel)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue,
              var body = try? Data(contentsOf: file)
        else {
            return send(c, 404, "text/plain", Data("not found".utf8))
        }
        // The page's <meta> CSP names a placeholder; fill it with the same
        // source list the header carries, so the two never disagree.
        if rel.hasSuffix(".html") {
            body = Data(String(decoding: body, as: UTF8.self)
                .replacingOccurrences(of: Self.connectSrcToken, with: connectSrc()).utf8)
        }
        send(c, 200, Self.mime(rel), body)
    }

    /// A request path to a file under Web/, or nil if it tries to climb out.
    /// Resolved segment by segment rather than by stripping "..".
    static func resolve(_ path: String) -> String? {
        var stack: [Substring] = []
        for seg in path.split(separator: "/", omittingEmptySubsequences: false) {
            if seg.isEmpty || seg == "." { continue }
            if seg == ".." {
                if stack.isEmpty { return nil }
                stack.removeLast()
            } else if seg.contains("\\") || seg.contains("\0") {
                return nil
            } else {
                stack.append(seg)
            }
        }
        return stack.isEmpty ? nil : stack.joined(separator: "/")
    }

    /// `connect-src`: 'self', this session's LAN relay, and the rendezvous and
    /// Nostr hosts. Never a bare scheme: `ws:` alone would let a script post
    /// the channel key to any host on the internet.
    private func connectSrc() -> String {
        let (lan, hosts) = lock.withLock { (lanRelay, relayHosts) }
        var out = "'self'"
        if let lan { out += " \(lan)" }
        var seen = Set<String>()
        for h in hosts where seen.insert(h).inserted {
            if h.hasPrefix("ws://") {
                let bare = String(h.dropFirst(5))
                out += " ws://\(bare) http://\(bare)"
            } else {
                out += " wss://\(h) https://\(h)"
            }
        }
        return out
    }

    private func send(_ c: NWConnection, _ code: Int, _ type: String, _ body: Data) {
        let head = "HTTP/1.1 \(code) X\r\n"
            + "Content-Type: \(type)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-cache\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "Referrer-Policy: no-referrer\r\n"
            + "Content-Security-Policy: default-src 'none'; script-src 'self'; "
            + "style-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; "
            + "font-src 'self'; manifest-src 'self'; connect-src \(connectSrc()); "
            + "base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    /// True the first time only: the continuation above is resumed once.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }

    static func mime(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "woff2": "font/woff2"
        case "ogg", "oga": "audio/ogg"
        case "mp3": "audio/mpeg"
        case "webmanifest": "application/manifest+json; charset=utf-8"
        default: "application/octet-stream"
        }
    }
}
