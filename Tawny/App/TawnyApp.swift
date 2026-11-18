import SwiftUI
import StoreKit

@main
struct TawnyApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.theme.colorScheme)
                .onOpenURL { model.open(url: $0) }
                // Tips bought while the app was closed, or approved later by
                // a parent, arrive here. Consumables must be finished.
                .task(priority: .background) {
                    for await update in Transaction.updates {
                        if case .verified(let t) = update { await t.finish() }
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Diag.shared.persist() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            Group {
                if model.sessions.isEmpty { WelcomeView() } else { HomeView() }
            }
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .role: RoleView()
                case .monitorSetup: MonitorSetupView()
                case .scan: ScanView()
                case .settings: SettingsView()
                case .help: HelpView()
                case .support: TipJarView()
                case .lightning: LightningTipView()
                case .diagnostics: DiagnosticsView()
                }
            }
        }
        .tint(Color.accentColor)
        .fullScreenCover(item: $model.live, onDismiss: { model.liveDidClose() }) { request in
            LiveView(request: request)
                .environment(model)
        }
        .sheet(item: $model.askName, onDismiss: { model.nameSheetClosed() }) { request in
            NameSheet(request: request)
                .environment(model)
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { spec in
            ForEach(spec.buttons) { b in
                Button(b.label, role: b.role) { b.action() }
            }
        } message: { spec in
            Text(spec.message)
        }
        #if DEBUG
        .overlay { DemoState.overlay(model) }
        #endif
    }
}
