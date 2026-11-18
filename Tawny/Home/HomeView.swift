import SwiftUI

/// Returning users: the pets this phone has watched or been, newest first,
/// one tap to pick a session back up.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(model.sessions) { s in
                    Button { model.resume(s) } label: { SessionRow(session: s) }
                        .swipeActions {
                            Button("Forget", role: .destructive) { model.forget(s) }
                        }
                        .accessibilityAction(named: "Forget") { model.forget(s) }
                }
            } header: {
                Text("Your sessions")
            } footer: {
                Text("Swipe left on a session to forget it.")
            }

            Section {
                Button { model.path.append(.monitorSetup) } label: {
                    Label("Make this phone a monitor", systemImage: "video.badge.plus")
                }
                Button { model.path.append(.scan) } label: {
                    Label("Connect to a monitor", systemImage: "qrcode.viewfinder")
                }
            }
        }
        .listStyle(.insetGrouped)
        .tawnyListBackground()
        .navigationTitle("Tawny")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.path.append(.settings) } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
    }
}

private struct SessionRow: View {
    let session: Session

    private var isMonitor: Bool { session.role == .station }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isMonitor ? "video.fill" : "eye.fill")
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.petName)
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text(isMonitor ? "This phone is the monitor" : "Watch from this phone")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkDim)
            }
            Spacer(minLength: 8)
            Text(session.lastUsed, format: .relative(presentation: .named))
                .font(.footnote)
                .foregroundStyle(Color.inkDim)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isMonitor ? "Starts the monitor again" : "Connects to this monitor")
    }
}
