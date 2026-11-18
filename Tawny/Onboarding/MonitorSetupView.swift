import SwiftUI

/// Name the pet, read the three things that make an iPhone a good monitor,
/// and start.
struct MonitorSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var petName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Pet camera", text: $petName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.go)
                    .focused($nameFocused)
                    .onSubmit(start)
            } header: {
                Text("Who's on camera?")
            } footer: {
                Text("Your other phones see this name when they connect.")
            }

            Section("Before you start") {
                SetupTip(symbol: "bolt.fill", text: "Plug this phone in. Streaming video all day uses a lot of battery.")
                SetupTip(symbol: "scope", text: "Point it at the spot your pet likes best: a bed, a crate, a sunny window.")
                SetupTip(symbol: "lock.open.fill", text: "Leave Tawny open. iPhone pauses the camera when another app is in front or the screen locks, so the screen stays on while Tawny is live.")
            }
        }
        .tawnyListBackground()
        .navigationTitle("Set up the Monitor")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button("Start the monitor", action: start)
                .buttonStyle(.tawnyPrimary)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
    }

    private func start() {
        nameFocused = false
        model.startMonitor(petName: petName)
    }
}

private struct SetupTip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(Color.ink)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 4)
    }
}

/// Asked once, before the first session: the name other phones see in the
/// "who's watching" list. Skipping is fine.
struct NameSheet: View {
    @Environment(AppModel.self) private var model
    let request: LiveRequest
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $name)
                        .textContentType(.givenName)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.continue)
                        .focused($focused)
                        .onSubmit(save)
                } header: {
                    Text("What should Tawny call you?")
                } footer: {
                    Text("Shown to the other phones in this session, so everyone knows who's watching. You can change it in Settings.")
                }
            }
            .tawnyListBackground()
            .navigationTitle("Your name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { model.finishNaming(request, name: nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue", action: save)
                        .disabled(model.cleanName(name).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    private func save() {
        let clean = model.cleanName(name)
        guard !clean.isEmpty else { return }
        model.finishNaming(request, name: clean)
    }
}
