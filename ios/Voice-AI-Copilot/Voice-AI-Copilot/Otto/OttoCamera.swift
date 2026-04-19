import SwiftUI
import AVFoundation
import Combine

#if os(iOS)
import UIKit

@MainActor
final class CameraController: NSObject, ObservableObject {
    @Published var isAuthorized: Bool = false
    @Published var lastCapture: UIImage?

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "otto.camera.session")
    private var captureContinuation: CheckedContinuation<UIImage?, Never>?

    func requestAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true; return true
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .video)
            isAuthorized = ok; return ok
        default:
            isAuthorized = false; return false
        }
    }

    func configureIfNeeded() {
        sessionQueue.async { [session, output] in
            guard session.inputs.isEmpty else { return }
            session.beginConfiguration()
            session.sessionPreset = .photo
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
        }
    }

    func start() {
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func capture() async -> UIImage? {
        await withCheckedContinuation { cont in
            self.captureContinuation = cont
            sessionQueue.async { [output] in
                let settings = AVCapturePhotoSettings()
                output.capturePhoto(with: settings, delegate: self)
            }
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let image: UIImage? = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        Task { @MainActor in
            self.lastCapture = image
            self.captureContinuation?.resume(returning: image)
            self.captureContinuation = nil
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// Self-contained camera backdrop for ActiveSessionView. Owns its own
// CameraController, requests permission on appear, shuts down on disappear.
// Falls back to transparent if not authorized so the UI behind still shows.

struct SessionCameraBackdrop: View {
    /// Optional externally-owned camera — passed in by ActiveSessionView so
    /// the same CameraController that drives the preview can also be used by
    /// OttoStore to snap a still when the mic is released. Falls back to a
    /// locally-owned controller if nothing is provided.
    @ObservedObject var camera: CameraController

    init(camera: CameraController) {
        self.camera = camera
    }

    var body: some View {
        Group {
            if camera.isAuthorized {
                CameraPreview(session: camera.session)
            } else {
                Color.clear
            }
        }
        .task {
            _ = await camera.requestAuthorization()
            camera.configureIfNeeded()
            camera.start()
        }
        .onDisappear { camera.stop() }
    }
}
#endif
