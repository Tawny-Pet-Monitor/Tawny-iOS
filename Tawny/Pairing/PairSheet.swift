import SwiftUI
import CoreImage.CIFilterBuiltins

/// The Monitor's pairing code, in a sheet over its own live camera: the
/// camera stays visible above it, so "is my pet in frame?" is answered by
/// looking. It drags between a sliver, half height and full height.
struct PairSheet: View {
    let petName: String
    let payload: String
    let expiresAt: Date
    let viewers: Int

    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text(viewers == 0 ? "Waiting for a phone" : "Add another phone")
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                    Text("On your other phone, open Tawny, tap Connect to a monitor and scan this code.")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkDim)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                QRCodeImage(text: payload)
                    .frame(width: 232, height: 232)
                    .padding(16)
                    .background(.white, in: .rect(cornerRadius: 20, style: .continuous))
                    .accessibilityLabel("Pairing code for \(petName)")

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(expiresAt.timeIntervalSince(context.date)))
                    Text("New code in \(left / 60):\(String(format: "%02d", left % 60))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Color.inkDim)
                        .accessibilityLabel("A new code appears in \(left / 60) minutes")
                }

                HStack(spacing: 12) {
                    ShareLink(item: payload, subject: Text("Watch \(petName) on Tawny"),
                              message: Text("Open this on your phone to watch \(petName) in Tawny.")) {
                        Label("Share link", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        UIPasteboard.general.string = payload
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .sensoryFeedback(.success, trigger: copied)
                }
                .buttonBorderShape(.capsule)

                Text("Codes change every 10 minutes. Anyone with this one can watch until then, so only share it with people you trust.")
                    .font(.footnote)
                    .foregroundStyle(Color.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .presentationBackground(Color.canvas)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .onChange(of: payload) { copied = false }
    }
}

/// A crisp QR code: black on white whatever the theme, so every camera reads it.
struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = QRCodeImage.render(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.black)
        }
    }

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
