import SwiftUI

/// Tawny's palette, from the asset catalog: "strawberry cheesecake" in light,
/// aged brass on espresso in dark (the same tokens as the Android app and
/// public/style.css). The accent is deepened in light mode so text and
/// white-on-accent buttons pass WCAG AA.
extension Color {
    static let canvas = Color("Canvas")
    static let panel = Color("Panel")
    static let raise = Color("Raise")
    static let line = Color("Line")
    static let ink = Color("Ink")
    static let inkDim = Color("InkDim")
    static let onAccent = Color("OnAccent")
    static let berry = Color("Berry")
    static let cream = Color("Cream")
    static let liveRed = Color("Live")
}

/// A full-width, 52 pt capsule for the one main action on a screen.
/// Drawn here rather than with `.borderedProminent` because the dark theme's
/// brass accent needs dark text on it, which the system style won't do.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.onAccent)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 24)
            .background(Color.accentColor.opacity(isEnabled ? 1 : 0.45), in: .capsule)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(.capsule)
    }
}

/// The quieter partner of PrimaryButtonStyle: same size, tinted text.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 24)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.16 : 0.08), in: .capsule)
            .contentShape(.capsule)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var tawnyPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var tawnySecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension View {
    /// Grouped lists and forms on Tawny's own canvas instead of system grey.
    func tawnyListBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.canvas)
    }
}
