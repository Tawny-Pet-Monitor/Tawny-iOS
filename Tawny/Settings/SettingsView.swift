import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "Tawny \(v) (\(b))"
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Your name", text: $model.myName)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .onSubmit { model.myName = model.cleanName(model.myName); model.nameAsked = true }
            } header: {
                Text("Your name")
            } footer: {
                Text("Shown to the other phones in a session, so everyone knows who's watching.")
            }

            Section("Appearance") {
                Picker("Theme", selection: $model.theme) {
                    ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                NavigationLink(value: Screen.support) {
                    Label("Support Tawny", systemImage: "heart")
                }
                NavigationLink(value: Screen.help) {
                    Label("How Tawny works", systemImage: "questionmark.circle")
                }
                Link(destination: Links.privacy) {
                    Label("Privacy policy", systemImage: "hand.raised")
                }
                if let mail = URL(string: "mailto:\(Links.supportEmail)?subject=Tawny%20for%20iPhone") {
                    Link(destination: mail) {
                        Label("Email support", systemImage: "envelope")
                    }
                }
            }

            Section {
                NavigationLink(value: Screen.diagnostics) {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            } footer: {
                Text("A record of what Tawny did on this phone, to send with a problem report. It never includes your video, your audio or your pairing keys.")
            }

            Section {
            } footer: {
                Text(version)
                    .frame(maxWidth: .infinity)
            }
        }
        .tawnyListBackground()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.myName = model.cleanName(model.myName) }
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section("How it works") {
                Paragraph("Tawny turns two phones into a pet monitor. One stays with your pet and streams live video and sound. The other is the one you carry.")
                Paragraph("You pair them once by scanning a code. After that, the Viewer finds the Monitor on its own, at home on Wi-Fi or from anywhere over the internet.")
                Paragraph("You can talk to your pet, play a chime, and take a snapshot from the Viewer.")
            }
            Section("Private by design") {
                Paragraph("Video and sound go straight from one phone to the other, encrypted end to end. There is no Tawny account, and nothing is recorded or stored on a server.")
                Paragraph("To find each other, the phones exchange a few small sealed messages through relays. The relays can't read them.")
            }
            Section("Using an iPhone as the Monitor") {
                Paragraph("Keep Tawny open on screen. iPhone stops the camera for any app that isn't in front, so the Monitor's screen stays on while Tawny is live. The dim button on the live screen darkens it.")
                Paragraph("Plug it in, and turn off Low Power Mode, which can pause the camera.")
            }
            Section("Mixing iPhone and Android") {
                Paragraph("Tawny for iPhone and Tawny for Android pair with each other. Use whichever phones you have.")
            }
        }
        .listStyle(.insetGrouped)
        .tawnyListBackground()
        .navigationTitle("How Tawny works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct Paragraph: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .foregroundStyle(Color.ink)
            .padding(.vertical, 4)
    }
}

struct DiagnosticsView: View {
    @State private var diag = Diag.shared
    @State private var confirmClear = false

    var body: some View {
        Group {
            if diag.lines.isEmpty {
                ContentUnavailableView(
                    "Nothing recorded yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Start a session and Tawny notes here what happens, step by step."))
            } else {
                ScrollView {
                    Text(diag.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                // Short logs sit at the top; long ones open on the newest line.
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
            }
        }
        .background(Color.canvas)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !diag.lines.isEmpty {
                    ShareLink(item: diag.text, subject: Text("Tawny diagnostics")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button("Clear", role: .destructive) { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Clear the diagnostics log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear log", role: .destructive) { diag.clear() }
        }
    }
}
