import SwiftUI
import AVFoundation
import WebKit

/// A live session, full screen. The call itself (video, talk-back, chimes,
/// snapshots, the controls on screen) is the shared web app; this view
/// starts it, keeps the screen awake, draws the Monitor's pairing code, and
/// turns the page's events into native alerts and navigation.
struct LiveView: View {
    @Environment(AppModel.self) private var model
    let request: LiveRequest

    @State private var engine: WebEngine?
    @State private var phase: Phase = .starting
    @State private var petName = ""

    // The Monitor's pairing code: rotated every ten minutes, and the page is
    // told each time (window.tawnyPairCode), because the page is what checks it.
    @State private var pairCode = randToken(8)
    @State private var pairExpires = Date().addingTimeInterval(LiveView.pairTTL)
    @State private var nostrPub: String?
    @State private var viewers = 0
    @State private var maxViewers = 5
    @State private var sheetShown = false
    @State private var detent: PresentationDetent = .medium

    @State private var shared: SharedFile?

    static let pairTTL: TimeInterval = 10 * 60

    enum Phase: Equatable { case starting, running, failed(String) }

    private var isMonitor: Bool { request.role == .station }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let engine {
                WebViewHost(webView: engine.webView)
                    .ignoresSafeArea()
            }

            switch phase {
            case .starting: startingOverlay
            case .failed(let message): failedOverlay(message)
            case .running: EmptyView()
            }

            if isMonitor, phase == .running, !sheetShown, viewers < maxViewers {
                addPhoneButton
            }
        }
        .task { await start() }
        .onDisappear { stop() }
        .task(id: pairExpires) { await rotatePairCodeWhenDue() }
        .sheet(isPresented: $sheetShown) { pairSheet }
        .sheet(item: $shared) { file in
            ActivityView(items: [file.url])
                .presentationDetents([.medium, .large])
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            pushBattery()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            pushBattery()
        }
    }

    // MARK: pieces

    private var startingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(isMonitor ? "Starting the camera" : "Connecting to \(request.petName)")
                .font(.headline)
                .foregroundStyle(.white)
            Button("Cancel") { model.endLive() }
                .buttonStyle(.bordered)
                .tint(.white)
                .padding(.top, 8)
        }
        .padding(24)
    }

    private func failedOverlay(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Tawny couldn't start", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { restart() }
                .buttonStyle(.borderedProminent)
            Button("Close") { model.endLive() }
        }
        .background(Color.canvas)
    }

    private var addPhoneButton: some View {
        Button { detent = .medium; sheetShown = true } label: {
            Label("Add a phone", systemImage: "qrcode")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(.ultraThinMaterial, in: .capsule)
                .environment(\.colorScheme, .dark)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 96)
        .padding(.trailing, 16)
        .accessibilityHint("Shows the pairing code again")
    }

    private var pairSheet: some View {
        PairSheet(
            petName: petName,
            payload: pairingPayload(
                key: request.key, name: petName, token: request.token, code: pairCode,
                expiresAtMs: ms(pairExpires), nostrPub: nostrPub),
            expiresAt: pairExpires,
            viewers: viewers)
        .presentationDetents([.height(150), .medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .interactiveDismissDisabled(viewers == 0)
    }

    // MARK: lifecycle

    private func start() async {
        guard engine == nil else { return }
        petName = request.petName
        let e = WebEngine()
        e.onEvent = { name, body in handle(name, body) }
        e.onFile = { url in shared = SharedFile(url: url) }
        engine = e

        UIApplication.shared.isIdleTimerDisabled = true
        configureAudio()

        guard let port = await LocalWebServer.shared.start() else {
            phase = .failed("This phone wouldn't let Tawny start its built-in web server. Close Tawny completely and open it again.")
            return
        }
        LocalWebServer.shared.configure(lanRelay: request.signalURL, relayHosts: model.relayHosts(for: request))
        let script = model.startScript(
            for: request,
            pairCode: isMonitor ? pairCode : request.pairCode,
            pairExpMs: isMonitor ? ms(pairExpires) : 0,
            systemDark: systemIsDark())
        Diag.shared.log("shell", "goLive role=\(request.role.rawValue) lan=\(request.signalURL ?? "-") "
            + "rv=\(request.rendezvous.isEmpty ? "NONE" : request.rendezvous) "
            + "ticket=\(request.token == nil ? "MISSING" : "yes") paircode=\(request.pairCode == nil && !isMonitor ? "none" : "yes")")
        e.load(port: Int(port), startScript: script)
        if isMonitor {
            UIDevice.current.isBatteryMonitoringEnabled = true
            sheetShown = true
        }
    }

    private func restart() {
        engine?.shutDown()
        engine = nil
        phase = .starting
        Task { await start() }
    }

    private func stop() {
        engine?.shutDown()
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.isBatteryMonitoringEnabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Diag.shared.persist()
    }

    /// Speaker, not the earpiece, and the voice-processing (echo-cancelling)
    /// mode: the Monitor plays your voice a metre from its own microphone.
    private func configureAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            Diag.shared.log("shell", "audio session: \(error.localizedDescription)")
        }
    }

    private func rotatePairCodeWhenDue() async {
        guard isMonitor else { return }
        let wait = pairExpires.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        guard !Task.isCancelled else { return }
        pairCode = randToken(8)
        pairExpires = Date().addingTimeInterval(LiveView.pairTTL)
        engine?.run("window.tawnyPairCode && window.tawnyPairCode(\"\(pairCode)\", \(ms(pairExpires)));")
    }

    private func pushBattery() {
        guard isMonitor, phase == .running else { return }
        let d = UIDevice.current
        guard d.batteryLevel >= 0 else { return }   // unknown (the simulator)
        let charging = d.batteryState == .charging || d.batteryState == .full
        engine?.run("window.tawnyBattery && window.tawnyBattery(\(Int((d.batteryLevel * 100).rounded())), \(charging));")
    }

    // MARK: the page's events

    private func handle(_ event: String, _ body: [String: Any]) {
        switch event {
        case "shell-started":
            phase = .running
            Task {
                try? await Task.sleep(for: .seconds(1))
                pushBattery()
            }
        case "shell-load-failed":
            phase = .failed(body["message"] as? String ?? "The live view didn't load.")
        case "shell-crashed":
            phase = .failed("The video engine stopped unexpectedly.")
        case "diag":
            if let line = body["line"] as? String { Diag.shared.log("page", line) }
        case "live", "idle", "paused", "resumed":
            Diag.shared.log("shell", event)
        case "ended":
            model.endLive()
        case "watching":
            viewers = (body["n"] as? NSNumber)?.intValue ?? 1
            maxViewers = (body["max"] as? NSNumber)?.intValue ?? maxViewers
            sheetShown = false
        case "waiting":
            viewers = 0
            maxViewers = (body["max"] as? NSNumber)?.intValue ?? maxViewers
            detent = .medium
            sheetShown = true
        case "nostrKey":
            if let pub = body["pub"] as? String, pub.count == 64,
               pub.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) { nostrPub = pub }
        case "petname":
            if let name = body["name"] as? String, !name.isEmpty {
                petName = String(name.prefix(40))
                model.renamePet(key: request.key, to: name)
            }
        case "myname":
            if let name = body["name"] as? String {
                model.myName = model.cleanName(name)
                model.nameAsked = true
            }
        case "theme":
            if let mode = body["mode"] as? String, let t = ThemeMode(rawValue: mode) { model.theme = t }
        case "coachDone":
            if let role = body["role"] as? String { model.markCoachSeen(role) }
        case "unreachable":
            model.monitorOffline(request)
        case "error":
            let message = body["message"] as? String
            switch body["reason"] as? String {
            case "full": model.monitorFull(message)
            case "expired": model.endLive(then: model.expiredAlert)
            case "noticket": model.sessionError(message)
            default:
                if isMonitor { model.sessionError(message) } else { model.monitorOffline(request) }
            }
        default:
            break
        }
    }

    private func systemIsDark() -> Bool {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.screen.traitCollection.userInterfaceStyle == .dark
    }

    private func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
}

private struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet: Save Image, Save Video, Messages, AirDrop.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
