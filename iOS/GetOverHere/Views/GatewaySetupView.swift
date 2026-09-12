import AVFoundation
import CoreImage.CIFilterBuiltins
import Network
import SwiftUI
import Vision
import VisionKit

struct GatewaySetupView: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var scanning = false
    @State private var cameraMessage: String?
    @State private var cameraRequestPending = false
    var body: some View {
        @Bindable var gateway = app.gateway
        NavigationStack {
            Form {
                Section("Wired connection") {
                    Text("Connect the two hubs by USB and enable Android USB tethering. Wi-Fi must remain enabled for the listener groups.")
                    if gateway.wiredInterfaces.interfaces.isEmpty {
                        Text("No wired interface detected. Check the cable and USB roles.").foregroundStyle(.orange)
                    } else {
                        Picker("Wired interface", selection: Binding(get: { gateway.wiredInterfaces.selectedName },
                            set: { gateway.wiredInterfaces.selectedName = $0 })) {
                            Text("Automatic (one interface)").tag("")
                            ForEach(gateway.wiredInterfaces.interfaces, id: \.name) { interface in
                                Text(interface.name).tag(interface.name)
                            }
                        }
                        Text(gateway.wiredInterfaces.addresses.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Section("Pair companion") {
                    Text(gateway.state).accessibilityIdentifier("gatewayState")
                    if gateway.role == .none, app.channelService.isCreator {
                        Button("Show Guide Pairing Code") { perform { try gateway.beginGuidePairing() } }
                            .accessibilityIdentifier("gatewayBegin")
                    }
                    if !gateway.publicQRCode.isEmpty {
                        if let image = qrImage(gateway.publicQRCode) {
                            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                                .accessibilityLabel("Public companion pairing QR")
                        }
                        Text(gateway.role == .guide ? "Scan this on the companion. Then scan its reply here." :
                            "Have the guide scan this reply and confirm. Then connect below.")
                        ShareLink("Share Public Pairing Code", item: gateway.publicQRCode)
                    }
                    Button("Scan Other Phone's QR") { requestScanner() }
                        .disabled(cameraRequestPending)
                    if let cameraMessage {
                        Text(cameraMessage).foregroundStyle(.orange)
                        if let settings = URL(string: UIApplication.openSettingsURLString) {
                            Link("Open Camera Settings", destination: settings)
                        }
                    }
                    TextField("Or paste public pairing code", text: $input, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("gatewayPairingInput")
                    Button("Read Pairing Code") { perform { try gateway.receivePairingQR(input); input = "" } }
                        .disabled(input.isEmpty).accessibilityIdentifier("gatewayReadPairing")
                    if gateway.state == "awaiting-guide-confirmation" {
                        Button("Confirm This Companion") { perform { try gateway.confirmCompanion() } }
                            .accessibilityIdentifier("gatewayConfirm")
                    }
                    if gateway.role == .companion {
                        Button("Connect to Confirmed Guide") { perform { try gateway.connectCompanion() } }
                            .accessibilityIdentifier("gatewayConnect")
                        Toggle("Keep screen awake while forwarding", isOn: $gateway.keepAwake)
                    }
                    if gateway.role != .none {
                        Button("Remove Companion Connection", role: .destructive) { gateway.stop() }
                            .accessibilityIdentifier("gatewayStop")
                    }
                    if let error = gateway.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("gatewayError") }
                }
                Section("Tour") {
                    Text("iOS listener branch: \(gateway.nativeBranchState)")
                    if let error = gateway.nativeBranchError { Text(error).foregroundStyle(.red) }
                    Button("Retry iOS Listener Branch") { gateway.retryNativeBranch() }.disabled(gateway.role == .none)
                    Text(gateway.roomName.isEmpty ? "No forwarded room" : gateway.roomName)
                    Text("One guide owns the microphone and presentation. Companion mode only forwards authenticated traffic.")
                        .font(.caption)
                }
            }
            .navigationTitle("Companion Gateway")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                GatewayQRScanner { value in
                    scanning = false
                    perform { try gateway.receivePairingQR(value) }
                }
            }
        }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { app.gateway.report(error) }
    }
    private func requestScanner() {
        cameraMessage = nil
        switch GatewayCameraAuthorization.action(for: AVCaptureDevice.authorizationStatus(for: .video)) {
        case .scan:
            scanning = true
        case .request:
            cameraRequestPending = true
            Task { @MainActor in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                cameraRequestPending = false
                if granted { scanning = true }
                else { cameraMessage = "Camera access was denied. Enable Camera in Settings, or paste the public pairing code." }
            }
        case .settings:
            cameraMessage = "Camera access is denied or restricted. Check Camera in Settings, or paste the public pairing code."
        }
    }
    private func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

enum GatewayCameraAuthorization {
    enum Action { case request, scan, settings }
    static func action(for status: AVAuthorizationStatus) -> Action {
        switch status {
        case .notDetermined: .request
        case .authorized: .scan
        case .denied, .restricted: .settings
        @unknown default: .settings
        }
    }
}

private struct GatewayQRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            return UIHostingController(rootView: ContentUnavailableView("Camera Scanner Unavailable", systemImage: "camera",
                description: Text("Allow Camera access, or use the public pairing text field.")))
        }
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() }
        catch { return UIHostingController(rootView: Text("Scanner failed: \(error.localizedDescription). Use the pairing text field.")) }
        return scanner
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        (uiViewController as? DataScannerViewController)?.stopScanning()
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for case .barcode(let item) in addedItems {
                if let text = item.payloadStringValue, text.hasPrefix("goh-hub:1:") {
                    delivered = true; scanner.stopScanning(); onCode(text); return
                }
            }
        }
    }
}
