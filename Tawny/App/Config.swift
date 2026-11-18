import Foundation

/// The build's network settings, read from the bundled `Web/config.json`: the
/// same file the page reads, so the shell and the page never disagree about
/// which rendezvous or Nostr relays this build meets on.
struct TawnyConfig: Sendable {
    var rendezvous: String
    var nostrRelays: [String]

    static let shared = TawnyConfig.load()

    static func load(bundle: Bundle = .main) -> TawnyConfig {
        guard let url = bundle.url(forResource: "config", withExtension: "json", subdirectory: "Web"),
              let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return TawnyConfig(rendezvous: "", nostrRelays: []) }
        let rendezvous = obj["rendezvous"] as? String ?? ""
        let nostr = (obj["nostr"] as? [String: Any])?["relays"] as? [String] ?? []
        return TawnyConfig(rendezvous: rendezvous, nostrRelays: nostr)
    }

    /// A Viewer away from home can still reach a Monitor: the rendezvous, or
    /// the Nostr relays, carry the pairing.
    var hasRemotePath: Bool { !rendezvous.isEmpty || !nostrRelays.isEmpty }
}

enum Links {
    static let privacy = URL(string: "https://tawny-rendezvous.tawny1.workers.dev/privacy")!
    static let supportEmail = "tawnysupport@pm.me"
    static let kofi = URL(string: "https://ko-fi.com/tawnyone")!
    static let lightningAddress = "loustrikes@strike.me"
    static let lightningWeb = URL(string: "https://strike.me/@loustrikes")!
}

/// `host[:port]` out of a `ws(s)://` / `http(s)://` URL, or nil.
func relayHost(_ url: String?) -> String? {
    guard var s = url?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    for prefix in ["wss://", "ws://", "https://", "http://"] where s.lowercased().hasPrefix(prefix) {
        s = String(s.dropFirst(prefix.count))
        break
    }
    if let i = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<i]) }
    return s.isEmpty ? nil : s
}

/// URL-safe base64 with no padding: the alphabet every Tawny key, ticket and
/// pairing code uses (`randToken` in MainActivity.kt).
func randToken(_ bytes: Int) -> String {
    var buf = [UInt8](repeating: 0, count: bytes)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
    precondition(status == errSecSuccess, "no randomness available")
    return Data(buf).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
