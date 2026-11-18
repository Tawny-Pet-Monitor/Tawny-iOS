import SwiftUI
import AVFoundation

/// Connect to a monitor: scan its QR code, or paste the link it shared.
struct ScanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var access: Access = .checking
    /// While an alert about a scanned code is up, further reads are ignored.
    @State private var paused = false

    enum Access { case checking, granted, denied, noCamera }

    var body: some View {
        ZStack {
            switch access {
            case .checking:
                Color.black.ignoresSafeArea()
            case .granted:
                QRScanner(paused: paused) { handle($0) }
                    .ignoresSafeArea()
                Viewfinder()
            case .denied:
                unavailable(
                    title: "Camera access is off",
                    symbol: "camera.fill",
                    message: "Tawny needs the camera to read your monitor's code. Turn it on in Settings, or paste the monitor's link instead.",
                    showSettings: true)
            case .noCamera:
                unavailable(
                    title: "No camera on this device",
                    symbol: "camera.fill",
                    message: "Paste the pairing link your monitor shared instead.",
                    showSettings: false)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if access == .granted { scanFooter }
        }
        .navigationTitle("Connect to a monitor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await checkAccess() }
    }

    private var scanFooter: some View {
        VStack(spacing: 12) {
            Text("Point at the code on your monitor phone")
                .font(.headline)
                .foregroundStyle(Color.ink)
            Text("On the monitor, the code is on its live screen. Hold it inside the frame.")
                .font(.subheadline)
                .foregroundStyle(Color.inkDim)
                .multilineTextAlignment(.center)
            PasteButton(payloadType: String.self) { strings in
                if let s = strings.first { Task { @MainActor in handle(s) } }
            }
            .buttonBorderShape(.capsule)
            .labelStyle(.titleAndIcon)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private func unavailable(title: String, symbol: String, message: String, showSettings: Bool) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if showSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
            }
            PasteButton(payloadType: String.self) { strings in
                if let s = strings.first { Task { @MainActor in handle(s) } }
            }
            .buttonBorderShape(.capsule)
        }
        .background(Color.canvas)
    }

    private func checkAccess() async {
        // No camera at all (the simulator, some iPads): don't ask for a
        // permission that could never be used.
        guard AVCaptureDevice.default(for: .video) != nil else { access = .noCamera; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: access = .granted
        case .notDetermined:
            access = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default: access = .denied
        }
    }

    private func handle(_ raw: String) {
        guard !paused, model.alert == nil else { return }
        paused = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let resume = { paused = false }
        switch model.readPairing(raw) {
        case .pairing(let p): model.confirm(p, onCancel: resume)
        case .expired: model.showExpired(); resume()
        case .notTawny: model.showNotTawny(keepScanning: resume)
        }
    }
}

/// A rounded square guide in the middle of the camera, with the rest dimmed.
private struct Viewfinder: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.68
            let rect = CGRect(x: (geo.size.width - side) / 2, y: (geo.size.height - side) / 2 - 40,
                              width: side, height: side)
            ZStack {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRoundedRect(in: rect, cornerSize: CGSize(width: 28, height: 28), style: .continuous)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 3)
                    .frame(width: side, height: side)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// AVFoundation's QR reader in a SwiftUI view. One session, started off the
/// main thread, stopped as soon as the view goes.
struct QRScanner: UIViewControllerRepresentable {
    var paused: Bool
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let c = QRScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ c: QRScannerController, context: Context) {
        c.onCode = onCode
        c.paused = paused
    }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var paused = false

    nonisolated(unsafe) private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "tawny.scanner")
    private var preview: AVCaptureVideoPreviewLayer?
    private var last: (value: String, at: Date)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer

        let output = AVCaptureMetadataOutput()
        sessionQueue.async { [session] in
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input), session.canAddOutput(output)
            else { return }
            session.beginConfiguration()
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
            }
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [session] in
            if !session.isRunning && !session.inputs.isEmpty { session.startRunning() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // The live view's WebRTC capture needs the camera next; hand it back.
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard let code = objects.first as? AVMetadataMachineReadableCodeObject,
              code.type == .qr, let value = code.stringValue else { return }
        MainActor.assumeIsolated {
            guard !paused else { return }
            if let last, last.value == value, Date().timeIntervalSince(last.at) < 2.5 { return }
            last = (value, Date())
            onCode?(value)
        }
    }
}
