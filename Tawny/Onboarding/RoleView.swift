import SwiftUI

/// "How will you use this phone?": the Monitor stays with the pet, the
/// Viewer comes with you.
struct RoleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("How will you use this phone?")
                    .font(.title3)
                    .foregroundStyle(Color.inkDim)
                    .padding(.bottom, 8)

                RoleCard(
                    symbol: "video.fill",
                    title: "The Monitor",
                    line: "Stays with your pet",
                    blurb: "Prop it up, plug it in and point the camera. It streams live video and sound, and shows a code so your other phones can watch."
                ) { model.path.append(.monitorSetup) }

                RoleCard(
                    symbol: "iphone.gen3",
                    title: "The Viewer",
                    line: "Watch from this phone",
                    blurb: "Check in on your pet from here, around the house on Wi-Fi or from out and about. You'll scan the code on your monitor."
                ) { model.path.append(.scan) }

                Button {
                    model.path.append(.help)
                } label: {
                    Label("How does Tawny work?", systemImage: "questionmark.circle")
                        .font(.body)
                        .frame(minHeight: 44)
                }
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Color.canvas)
        .navigationTitle("Set up Tawny")
    }
}

private struct RoleCard: View {
    let symbol: String
    let title: String
    let line: String
    let blurb: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                    Text(line)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(blurb)
                        .font(.subheadline)
                        .foregroundStyle(Color.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.inkDim)
                    .padding(.top, 16)
            }
            .padding(20)
            .background(Color.panel, in: .rect(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.line))
            .contentShape(.rect(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(line)
    }
}

#Preview {
    NavigationStack { RoleView() }.environment(AppModel())
}
