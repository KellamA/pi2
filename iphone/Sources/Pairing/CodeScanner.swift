
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// What the camera can do for the scanner.
enum CameraState: Equatable, Sendable {
    /// Not asked yet, or being asked.
    case unknown
    case ready
    /// The person said no, or the phone's restrictions do (Settings › pi² › Camera).
    case denied
    /// No camera: the simulator has none.
    case none

    /// Where the camera stands now, without asking.
    static var current: CameraState {
        guard AVCaptureDevice.default(for: .video) != nil else { return .none }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .ready
        case .notDetermined: return .unknown
        default: return .denied
        }
    }

    /// Asks for the camera once, if it was never asked (the text iOS shows is the project's, docs/iphone-app.md).
    static func ask() async -> CameraState {
        guard current == .unknown else { return current }
        return await AVCaptureDevice.requestAccess(for: .video) ? .ready : .denied
    }
}

/// The phone's own camera, reading QR codes (3.1: a release build takes a pairing from nothing else). Each code read is
/// handed over as its text, once; what it is, RemoteKit's reader decides.
struct CodeScanner: UIViewRepresentable {
    let found: @MainActor (String) -> Void

    func makeUIView(context: Context) -> ScannerView {
        let view = ScannerView()
        view.found = found
        view.start()
        return view
    }

    func updateUIView(_ view: ScannerView, context: Context) {
        view.found = found
    }

    static func dismantleUIView(_ view: ScannerView, coordinator: ()) {
        view.stop()
    }

    final class ScannerView: UIView, AVCaptureMetadataOutputObjectsDelegate {
        var found: (@MainActor (String) -> Void)?
        private let session = AVCaptureSession()
        private var last: String?

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        func start() {
            guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = layer as? AVCaptureVideoPreviewLayer
            preview?.session = session
            preview?.videoGravity = .resizeAspectFill
            let session = session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        func stop() {
            let session = session
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            let texts = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            MainActor.assumeIsolated {
                for text in texts where text != last {
                    last = text
                    found?(text)
                }
            }
        }
    }
}
