import SwiftUI

/// First launch: what Tawny is, in two sentences, and the two ways in.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                OwlMark(size: 128)
                    .shadow(color: Color.berry.opacity(0.25), radius: 24, y: 12)
                    .padding(.top, 24)

                VStack(spacing: 12) {
                    Text("Tawny")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Text("Keep an eye on your pet from the next room or across town.")
                        .font(.title3)
                        .foregroundStyle(Color.ink)
                    Text("You need two phones: one stays with your pet, one comes with you. No accounts, ever.")
                        .font(.body)
                        .foregroundStyle(Color.inkDim)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Centred in the space above the buttons while it fits; scrolls when
        // larger text sizes make it taller than the screen.
        .defaultScrollAnchor(.center, for: .alignment)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button("Get started") { model.path.append(.role) }
                    .buttonStyle(.tawnyPrimary)
                Button("I already have a code to scan") { model.path.append(.scan) }
                    .buttonStyle(.tawnySecondary)
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(Color.canvas)
        }
        .background(Color.canvas)
        .toolbar(.hidden, for: .navigationBar)
    }
}

#Preview {
    NavigationStack { WelcomeView() }.environment(AppModel())
}
