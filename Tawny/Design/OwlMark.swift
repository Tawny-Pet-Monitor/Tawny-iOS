import SwiftUI

/// The app icon's art, an owl between a cat and a dog, drawn as vectors from
/// tawny-icon.svg (64-unit artboard) so it stays sharp at any size and the owl
/// can blink. The blink is the welcome screen's one moving thing; it never
/// runs with Reduce Motion on.
struct OwlMark: View {
    var size: CGFloat = 120
    var blinks = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var eyesClosed = false

    private let berry = Color(red: 0xD2 / 255, green: 0x4B / 255, blue: 0x6D / 255)
    private let cream = Color(red: 0xF7 / 255, green: 0xEF / 255, blue: 0xE3 / 255)

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 64
            ctx.scaleBy(x: s, y: s)
            let full = CGRect(x: 0, y: 0, width: 64, height: 64)
            ctx.fill(Path(full), with: .color(berry))

            // The cat (left) and the dog (right).
            var pets = Path()
            pets.move(to: CGPoint(x: 9, y: 24))
            pets.addLine(to: CGPoint(x: 7.5, y: 13.5))
            pets.addLine(to: CGPoint(x: 16, y: 19))
            pets.addLine(to: CGPoint(x: 24, y: 19))
            pets.addLine(to: CGPoint(x: 22.5, y: 24))
            pets.closeSubpath()
            pets.addEllipse(in: circle(16, 31, 10))
            pets.addEllipse(in: circle(48, 31, 10))
            pets.addEllipse(in: CGRect(x: 38.5 - 4.6, y: 30 - 9, width: 9.2, height: 18))
            pets.addEllipse(in: CGRect(x: 57.5 - 4.6, y: 30 - 9, width: 9.2, height: 18))
            ctx.fill(pets, with: .color(cream))

            // The owl's outline (its silhouette at 1.17x, in berry) separates
            // it from the two either side; then the owl itself.
            let owl = owlSilhouette()
            let outline = owl.applying(
                CGAffineTransform(translationX: 32, y: 33).scaledBy(x: 1.17, y: 1.17).translatedBy(x: -32, y: -33))
            ctx.fill(outline, with: .color(berry))
            ctx.fill(owl, with: .color(cream))

            // Cheeks.
            ctx.fill(Path(ellipseIn: circle(21.8, 39.2, 2.8)), with: .color(berry.opacity(0.42)))
            ctx.fill(Path(ellipseIn: circle(42.2, 39.2, 2.8)), with: .color(berry.opacity(0.42)))

            // Eyes: shut to a soft line during a blink.
            if eyesClosed {
                var lids = Path()
                lids.addRoundedRect(in: CGRect(x: 21.2, y: 32.4, width: 9.6, height: 1.8), cornerSize: CGSize(width: 0.9, height: 0.9))
                lids.addRoundedRect(in: CGRect(x: 33.2, y: 32.4, width: 9.6, height: 1.8), cornerSize: CGSize(width: 0.9, height: 0.9))
                ctx.fill(lids, with: .color(berry))
            } else {
                ctx.fill(Path(ellipseIn: circle(26, 33.2, 4.8)), with: .color(berry))
                ctx.fill(Path(ellipseIn: circle(38, 33.2, 4.8)), with: .color(berry))
                ctx.fill(Path(ellipseIn: circle(24.5, 31.7, 1.7)), with: .color(cream))
                ctx.fill(Path(ellipseIn: circle(36.5, 31.7, 1.7)), with: .color(cream))
            }

            // Beak.
            var beak = Path()
            beak.move(to: CGPoint(x: 32, y: 38.6))
            beak.addLine(to: CGPoint(x: 34.5, y: 42.6))
            beak.addLine(to: CGPoint(x: 29.5, y: 42.6))
            beak.closeSubpath()
            ctx.fill(beak, with: .color(berry))
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
        .accessibilityHidden(true)
        .task(id: blinks && !reduceMotion) {
            guard blinks && !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 3.5...6.5)))
                eyesClosed = true
                try? await Task.sleep(for: .milliseconds(140))
                eyesClosed = false
            }
        }
    }

    private func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGRect {
        CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
    }

    /// Ear tufts and body: `M21 25.5 C 19.5 18, 20.5 14.5, 23 15.5 …` plus
    /// the 14.5 × 15 body ellipse at (32, 35.5).
    private func owlSilhouette() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 21, y: 25.5))
        p.addCurve(to: CGPoint(x: 23, y: 15.5), control1: CGPoint(x: 19.5, y: 18), control2: CGPoint(x: 20.5, y: 14.5))
        p.addCurve(to: CGPoint(x: 29.6, y: 21), control1: CGPoint(x: 25.8, y: 16.6), control2: CGPoint(x: 28, y: 19))
        p.addLine(to: CGPoint(x: 35.4, y: 21))
        p.addCurve(to: CGPoint(x: 42, y: 15.5), control1: CGPoint(x: 37, y: 19), control2: CGPoint(x: 39.2, y: 16.6))
        p.addCurve(to: CGPoint(x: 44, y: 25.5), control1: CGPoint(x: 44.5, y: 14.5), control2: CGPoint(x: 45.5, y: 18))
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: 32 - 14.5, y: 35.5 - 15, width: 29, height: 30))
        return p
    }
}

#Preview {
    OwlMark(size: 200)
}
