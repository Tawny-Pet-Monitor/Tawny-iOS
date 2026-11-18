import SwiftUI
import Observation

enum Role: String, Codable, Sendable {
    /// The phone that stays with the pet (the page calls it the station).
    case station
    case viewer
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
    var label: String {
        switch self {
        case .system: "Match iPhone"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// A pairing this phone has used, so it can be picked up again in one tap.
/// Mirrors the Android shell's `recentSessions`.
struct Session: Codable, Identifiable, Hashable {
    var role: Role
    var key: String
    var petName: String
    /// Viewer: the Monitor's LAN relay (`ws://<ip>:<port>`), if it had one.
    var signalURL: String?
    /// The rendezvous admission ticket: the Monitor's own, or the one a
    /// Viewer scanned.
    var token: String?
    /// Viewer: a relay the pairing link named and PairLink trusted.
    var relay: String?
    /// Viewer: the pairing code it scanned, presented again on a retry.
    var pairCode: String? = nil
    /// Viewer: the Monitor's Nostr public key from the code it scanned.
    var nostrStation: String? = nil
    var lastUsed: Date
    var id: String { "\(role.rawValue):\(key)" }
}

/// One live session, about to start or running.
struct LiveRequest: Identifiable, Equatable {
    let id = UUID()
    var role: Role
    var key: String
    var petName: String
    var signalURL: String?
    var rendezvous: String
    var token: String?
    /// Viewer: the code it scanned, presented once to be let in.
    var pairCode: String?
    /// Viewer: the Monitor's Nostr key from the code it scanned.
    var nostrStation: String?
}

enum Screen: Hashable {
    case role, monitorSetup, scan, settings, help, support, lightning, diagnostics
}

struct AlertButton: Identifiable {
    let id = UUID()
    var label: String
    var role: ButtonRole?
    var action: () -> Void = {}
}

struct AlertSpec: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var buttons: [AlertButton]
}

@MainActor @Observable
final class AppModel {
    let config = TawnyConfig.shared

    var path: [Screen] = []
    var live: LiveRequest?
    /// Asked once, before the first session: the name other phones see.
    var askName: LiveRequest?
    var alert: AlertSpec?
    /// Shown after the live screen has finished closing.
    private var alertAfterLive: AlertSpec?

    private(set) var sessions: [Session] = []

    var myName: String {
        didSet { defaults.set(myName, forKey: Keys.myName) }
    }
    var nameAsked: Bool {
        didSet { defaults.set(nameAsked, forKey: Keys.nameAsked) }
    }
    var theme: ThemeMode {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }
    private(set) var coachSeen: Set<String>

    private let defaults: UserDefaults

    private enum Keys {
        static let sessions = "sessions"
        static let myName = "myName"
        static let nameAsked = "nameAsked"
        static let theme = "theme"
        static let coachSeen = "coachSeen"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        myName = defaults.string(forKey: Keys.myName) ?? ""
        nameAsked = defaults.bool(forKey: Keys.nameAsked)
        theme = ThemeMode(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        coachSeen = Set(defaults.stringArray(forKey: Keys.coachSeen) ?? [])
        if let data = defaults.data(forKey: Keys.sessions),
           let list = try? JSONDecoder().decode([Session].self, from: data) {
            sessions = list
        }
        #if DEBUG
        DemoState.apply(to: self)
        #endif
    }

    // MARK: sessions

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) { defaults.set(data, forKey: Keys.sessions) }
    }

    func upsert(_ s: Session) {
        sessions.removeAll { $0.id == s.id }
        sessions.insert(s, at: 0)
        if sessions.count > 8 { sessions.removeLast(sessions.count - 8) }
        saveSessions()
    }

    func forget(_ s: Session) {
        sessions.removeAll { $0.id == s.id }
        saveSessions()
    }

    func forgetAll() {
        sessions.removeAll()
        saveSessions()
    }

    func renamePet(key: String, to name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !clean.isEmpty else { return }
        for i in sessions.indices where sessions[i].key == key { sessions[i].petName = clean }
        saveSessions()
    }

    func markCoachSeen(_ role: String) {
        guard role == "viewer" || role == "station" else { return }
        coachSeen.insert(role)
        defaults.set(Array(coachSeen), forKey: Keys.coachSeen)
    }

    // MARK: starting sessions

    /// A new Monitor: a fresh channel key, and a rendezvous ticket when this
    /// build has a rendezvous to present it to.
    func startMonitor(petName: String) {
        let name = String(petName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let s = Session(
            role: .station, key: randToken(16),
            petName: name.isEmpty ? PairLink.defaultName : name,
            signalURL: nil,
            token: config.rendezvous.isEmpty ? nil : randToken(16),
            relay: nil, lastUsed: Date())
        upsert(s)
        Diag.shared.log("shell", "new monitor channel, ticket=\(s.token == nil ? "none" : "yes")")
        go(request(for: s))
    }

    func resume(_ s: Session) {
        var s = s
        s.lastUsed = Date()
        if s.role == .station && s.token == nil && !config.rendezvous.isEmpty { s.token = randToken(16) }
        upsert(s)
        go(request(for: s))
    }

    private func request(for s: Session) -> LiveRequest {
        LiveRequest(
            role: s.role, key: s.key, petName: s.petName,
            signalURL: s.role == .viewer ? s.signalURL : nil,
            rendezvous: s.relay ?? config.rendezvous,
            token: s.token,
            pairCode: s.role == .viewer ? s.pairCode : nil,
            nostrStation: s.role == .viewer ? s.nostrStation : nil)
    }

    private func go(_ r: LiveRequest) {
        path.removeAll()
        if nameAsked { live = r } else { askName = r }
    }

    func finishNaming(_ r: LiveRequest, name: String?) {
        if let name { myName = cleanName(name) }
        nameAsked = true
        liveAfterName = r
        askName = nil
    }

    /// The live screen opens once the name sheet has fully gone; presenting
    /// it while the sheet is still animating away is dropped by UIKit.
    func nameSheetClosed() {
        if let r = liveAfterName {
            liveAfterName = nil
            live = r
        }
    }
    private var liveAfterName: LiveRequest?

    /// The page's own rule (cleanName in app.js): no control or invisible
    /// formatting characters, runs of space collapsed, 24 characters at most.
    func cleanName(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { u in
            let v = u.value
            return !(v <= 0x1F || (0x7F...0x9F).contains(v) || (0x200B...0x200F).contains(v)
                || (0x2028...0x202E).contains(v) || (0x2060...0x206F).contains(v) || v == 0xFEFF)
        }
        let collapsed = String(String.UnicodeScalarView(kept))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(24))
    }

    // MARK: pairing

    enum ScanOutcome { case pairing(Pairing), notTawny, expired }

    func readPairing(_ raw: String) -> ScanOutcome {
        guard let p = PairLink.parse(
            raw, preferredRelayHost: nil,
            buildRelayHost: relayHost(config.rendezvous),
            hasRendezvous: config.hasRemotePath)
        else {
            Diag.shared.log("shell", "scanned something that is not a Tawny code")
            return .notTawny
        }
        return p.isExpired() ? .expired : .pairing(p)
    }

    /// "Connect to this monitor?": the gate on every pairing, scanned, pasted
    /// or opened from a link.
    func confirm(_ p: Pairing, onCancel: @escaping () -> Void = {}) {
        let whereText = p.signal != nil ? "your Wi-Fi" : "the internet"
        alert = AlertSpec(
            title: "Connect to “\(p.name)”?",
            message: "This code connects to a monitor over \(whereText).\n\nOnly connect if this is your own monitor.",
            buttons: [
                AlertButton(label: "Connect") { [weak self] in self?.join(p) },
                AlertButton(label: "Not now", role: .cancel, action: onCancel),
            ])
    }

    func join(_ p: Pairing) {
        if p.isExpired() { showExpired(); return }
        let adopt = p.relayTrusted ? p.relay : nil
        Diag.shared.log("shell", "pair accepted lan=\(p.signal ?? "-") relay=\(p.relay ?? "-")"
            + "\(p.relay != nil && adopt == nil ? " (not adopted)" : "") ticket=\(p.token == nil ? "MISSING" : "yes")"
            + " code=\(p.code == nil ? "none" : "yes")")
        let s = Session(role: .viewer, key: p.key, petName: p.name, signalURL: p.signal,
                        token: p.token, relay: adopt, pairCode: p.code, nostrStation: p.nostrStation,
                        lastUsed: Date())
        upsert(s)
        let r = request(for: s)
        // Called from the "Connect" alert's button: let the alert finish
        // leaving before the next screen is presented over it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            self.go(r)
        }
    }

    func showExpired() { alert = expiredAlert }

    var expiredAlert: AlertSpec {
        AlertSpec(
            title: "That code has expired",
            message: "Pairing codes stop working ten minutes after the monitor shows them, so an old photo of one "
                + "can't be used later.\n\nOn the monitor phone, go back to its pairing screen for a fresh code, and scan that one.",
            buttons: [
                AlertButton(label: "Scan again") { [weak self] in self?.path = [.scan] },
                AlertButton(label: "Not now", role: .cancel),
            ])
    }

    func showNotTawny(keepScanning: @escaping () -> Void) {
        alert = AlertSpec(
            title: "Not a Tawny code",
            message: "That QR code isn't a Tawny pairing code. The one to scan is on the monitor phone's pairing screen.",
            buttons: [AlertButton(label: "Keep scanning", action: keepScanning)])
    }

    /// A `tawny://pair` link opened from Messages, Mail or the camera.
    func open(url: URL) {
        guard live == nil else {
            Diag.shared.log("shell", "pairing link ignored: a session is live")
            return
        }
        switch readPairing(url.absoluteString) {
        case .pairing(let p): confirm(p)
        case .expired: showExpired()
        case .notTawny:
            alert = AlertSpec(
                title: "This link can't be used",
                message: "It isn't a complete Tawny pairing link. Ask for a fresh one from the monitor phone.",
                buttons: [AlertButton(label: "OK")])
        }
    }

    // MARK: ending sessions

    /// Close the live screen, then show `alert` once it has gone.
    func endLive(then alert: AlertSpec? = nil) {
        alertAfterLive = alert
        live = nil
    }

    func liveDidClose() {
        if let a = alertAfterLive {
            alertAfterLive = nil
            alert = a
        }
    }

    func monitorOffline(_ r: LiveRequest) {
        endLive(then: AlertSpec(
            title: "Monitor isn't on yet",
            message: "Open Tawny on \(r.petName)'s monitor phone and leave it on its live screen, then try again.",
            buttons: [
                AlertButton(label: "Try again") { [weak self] in
                    guard let self, let s = self.sessions.first(where: { $0.key == r.key && $0.role == .viewer }) else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        self.resume(s)
                    }
                },
                AlertButton(label: "Close", role: .cancel),
            ]))
    }

    func monitorFull(_ message: String?) {
        endLive(then: AlertSpec(
            title: "This monitor is full",
            message: message ?? "Five phones are already watching. Ask someone to leave, then try again.",
            buttons: [AlertButton(label: "OK")]))
    }

    func sessionError(_ message: String?) {
        endLive(then: AlertSpec(
            title: "The session couldn't start",
            message: message ?? "Something went wrong while connecting. Try again in a moment.",
            buttons: [AlertButton(label: "OK")]))
    }

    // MARK: what the page is told

    /// The `servers` block of tawnyStart's options. Only a relay adopted from
    /// a pairing link differs from the build's, and then the build's own
    /// rendezvous is the fallback.
    func servers(for r: LiveRequest) -> [String: Any] {
        var o: [String: Any] = [:]
        if r.rendezvous != config.rendezvous && !config.rendezvous.isEmpty { o["fallback"] = config.rendezvous }
        return o
    }

    /// Hosts the page may reach: its rendezvous (and the build's fallback)
    /// and the Nostr relays. A `ws://` relay is named with its scheme.
    func relayHosts(for r: LiveRequest) -> [String] {
        var hosts: [String] = []
        for url in [r.rendezvous, config.rendezvous] + config.nostrRelays {
            guard let h = relayHost(url) else { continue }
            let entry = url.lowercased().hasPrefix("ws://") ? "ws://\(h)" : h
            if !hosts.contains(entry) { hosts.append(entry) }
        }
        return hosts
    }

    /// The JavaScript that drops the page into the session: the same call
    /// MainActivity makes, `tawnyStart(role, key, name, signal, rendezvous,
    /// token, opts)`, with every value JSON-encoded.
    func startScript(for r: LiveRequest, pairCode: String?, pairExpMs: Int64, systemDark: Bool) -> String {
        var opts: [String: Any] = [
            "theme": theme.rawValue,
            "systemTheme": systemDark ? "dark" : "light",
            "coachSeen": Array(coachSeen),
            "motion": UIAccessibility.isReduceMotionEnabled ? "off" : "on",
            "announce": "off",
            "myName": myName,
            "lang": "en",
            "pairExp": pairExpMs,
            "servers": servers(for: r),
        ]
        opts["pairCode"] = pairCode ?? NSNull()
        opts["nostrStation"] = (r.role == .viewer ? r.nostrStation : nil) ?? NSNull()
        let args: [Any] = [
            r.role.rawValue, r.key, r.petName,
            r.signalURL ?? NSNull(), r.rendezvous, r.token ?? NSNull(), opts,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return "window.tawnyStart && window.tawnyStart.apply(null, \(json));"
    }
}
