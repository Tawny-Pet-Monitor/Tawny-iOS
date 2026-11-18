import Foundation
import Observation

/// The flight recorder. The failures worth chasing happen on cellular, on a
/// phone nobody can attach a debugger to, so the page ships its story here
/// (bridge event `diag`) and the shell adds its own. Settings → Diagnostics
/// shows it and shares it. It never holds a channel key or a ticket: the page
/// already redacts its lines, and LAN addresses are masked below.
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

    var text: String { lines.joined(separator: "\n") }

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

    /// `192.168.1.50` → `192.168.x.x`: enough to tell a home LAN from a
    /// carrier address, not enough to place the house.
    nonisolated static func redact(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\b(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}\b"#) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: "$1.$2.x.x")
    }
}
