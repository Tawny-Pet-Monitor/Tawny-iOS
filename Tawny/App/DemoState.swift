#if DEBUG
import SwiftUI

/// Screenshot mode, Debug builds only. CI launches the simulator build with
/// `-TawnyDemo <screen>` and photographs each screen in light and dark, so
/// the UI can be reviewed without a Mac. Never compiled into Release.
enum DemoState {
    static var screen: String? { UserDefaults.standard.string(forKey: "TawnyDemo") }

    @MainActor
    static func apply(to model: AppModel) {
        guard let screen else { return }
        model.forgetAll()
        model.nameAsked = true
        if screen != "welcome" && screen != "role" && screen != "scan" && screen != "setup" {
            let now = Date()
            for s in [
                Session(role: .viewer, key: "demoKeyViewer000001", petName: "Biscuit", signalURL: nil,
                        token: nil, relay: nil, lastUsed: now.addingTimeInterval(-7_200)),
                Session(role: .station, key: "demoKeyMonitor00002", petName: "Miso and Pickle", signalURL: nil,
                        token: nil, relay: nil, lastUsed: now.addingTimeInterval(-26 * 3_600)),
                Session(role: .viewer, key: "demoKeyViewer000003", petName: "Grandma's cat", signalURL: nil,
                        token: nil, relay: nil, lastUsed: now.addingTimeInterval(-6 * 86_400)),
            ].reversed() { model.upsert(s) }
            model.myName = "Lou"
        }
        switch screen {
        case "role": model.path = [.role]
        case "setup": model.path = [.role, .monitorSetup]
        case "scan": model.path = [.scan]
        case "settings": model.path = [.settings]
        case "support": model.path = [.settings, .support]
        case "lightning": model.path = [.settings, .support, .lightning]
        case "help": model.path = [.settings, .help]
        case "diagnostics":
            Diag.shared.log("shell", "goLive role=viewer lan=- rv=wss://tawny-rendezvous.example ticket=yes")
            Diag.shared.log("page", "nostr: meeting on 3 relays")
            Diag.shared.log("page", "path=direct (local srflx/udp, remote srflx)")
            model.path = [.settings, .diagnostics]
        case "confirm":
            model.confirm(Pairing(signal: "ws://192.168.1.50:8820", key: "demoKeyViewer000009", name: "Biscuit",
                                  token: nil, code: nil, expiresAt: 0, relay: nil, nostrStation: nil))
        case "name":
            model.nameAsked = false
            model.askName = LiveRequest(role: .viewer, key: "demoKeyViewer000001", petName: "Biscuit",
                                        signalURL: nil, rendezvous: "", token: nil)
        default: break
        }
    }

    /// The pairing sheet over a stand-in for the camera, which the
    /// simulator does not have.
    @MainActor @ViewBuilder
    static func overlay(_ model: AppModel) -> some View {
        if screen == "pairsheet" {
            DemoPairScreen()
        }
    }
}

private struct DemoPairScreen: View {
    @State private var shown = true
    var body: some View {
        LinearGradient(colors: [Color(white: 0.28), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .sheet(isPresented: $shown) {
                PairSheet(
                    petName: "Miso and Pickle",
                    payload: pairingPayload(key: "GpgOcJxe4H6eAhLZpgZ72w", name: "Miso and Pickle",
                                            token: "NvM7UXwo8X79vagb9VARxQ", code: "WXXHeH07nDk",
                                            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1000) + 582_000,
                                            nostrPub: String(repeating: "c", count: 64)),
                    expiresAt: Date().addingTimeInterval(582),
                    viewers: 0)
                .presentationDetents([.height(150), .medium, .large], selection: .constant(.medium))
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .interactiveDismissDisabled()
            }
    }
}
#endif
