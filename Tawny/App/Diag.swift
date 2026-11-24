import Foundation
import Observation

/// The flight recorder. The failures worth chasing happen on cellular, on a
/// phone nobody can attach a debugger to, so the page ships its story here
/// (bridge event `diag`) and the shell adds its own. Settings → Diagnostics
/// shows it and shares it. Every line is cut down to what the privacy policy
/// says a log holds (see `redact`): no address, peer id, link secret or name.
@MainActor @Observable
final class Diag {
    static let shared = Diag()

    private(set) var lines: [String] = []
    private let cap = 800
    private let file: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("diagnostics.log")

    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        if let file, let text = try? String(contentsOf: file, encoding: .utf8) {
            lines = text.split(separator: "\n").suffix(cap).map(String.init)
        }
    }

    func log(_ tag: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) [\(tag)] \(Diag.redact(String(message.prefix(400))))"
        lines.append(line)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        #if DEBUG
        print(line)
        #endif
    }

    /// Log from any thread.
    nonisolated static func post(_ tag: String, _ message: String) {
        Task { @MainActor in Diag.shared.log(tag, message) }
    }

    /// What Settings shows and shares: cut down again, so lines an older
    /// build wrote to the file before these rules can't leave the phone.
    var text: String { lines.map(Diag.redact).joined(separator: "\n") }

    func clear() {
        lines.removeAll()
        persist()
    }

    /// Written when the app leaves the foreground, so a log survives the app
    /// being killed in the background.
    func persist() {
        guard let file else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// What a shared log never carries (the privacy policy: hashed room
    /// identifiers and connection events, never a key or an IP address):
    /// - IPv4 addresses, as `<lan-ip>` (home network) or `<ip>`; the phone's
    ///   own loopback stays;
    /// - a peer's id or key: the long hex relays and Nostr give phones. The
    ///   room id after `room=` stays: it is a hash, and lines two phones'
    ///   logs up;
    /// - a pairing link's key, ticket, code or Monitor key;
    /// - names people typed: `name=…`, and `"name"`/`"label"` in a frame;
    /// - a home or tailnet host name (`*.ts.net`, `*.local`, …), which can
    ///   carry a person's or a household's name.
    nonisolated static func redact(_ s: String) -> String {
        var out = s
        if let ip = try? NSRegularExpression(pattern: #"(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])"#) {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in ip.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let parts = (1...4).compactMap { Int(ns.substring(with: m.range(at: $0))) }
                let whole = ns.substring(with: m.range)
                if parts.count != 4 || parts.contains(where: { $0 > 255 }) || whole == "127.0.0.1" {
                    result += whole
                } else {
                    let (a, b) = (parts[0], parts[1])
                    let lan = a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                        || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
                    result += lan ? "<lan-ip>" : "<ip>"
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        let rules: [(String, String)] = [
            (#"(?<!room=)(?<![0-9A-Za-z])(?=[0-9a-f]*[a-f])[0-9a-f]{8,}(?![0-9A-Za-z])"#, "<id>"),
            (#"([?&#](?:k|t|c|np)=)[^&\s"]+"#, "$1<…>"),
            (#"(\bname=)("[^"]*"|\S+)"#, "$1<name>"),
            (#"("(?:name|label|myName|device)"\s*:\s*)"[^"]*""#, "$1\"<name>\""),
            (#"(?<![\w.-])[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:ts\.net|local|lan|home\.arpa|internal)(?![\w.-])"#, "<private-host>"),
        ]
        for (pattern, template) in rules {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}
