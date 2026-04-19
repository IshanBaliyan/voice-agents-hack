//
//  CameraManager.swift
//  iphone-test
//

import AVFoundation
import UIKit
import SwiftUI

// MARK: - CameraManager

@MainActor
@Observable
final class CameraManager {

    let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var pendingCompletion: ((String?) -> Void)?
    private let sessionQueue = DispatchQueue(label: "camera.session")

    init() {
        let session = captureSession
        let output = photoOutput
        sessionQueue.async {
            CameraManager.configureSession(session: session, output: output)
        }
    }

    private nonisolated static func configureSession(
        session: AVCaptureSession,
        output: AVCapturePhotoOutput
    ) {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
        session.startRunning()
    }

    /// Capture a single JPEG frame. Completion is called on the main actor.
    func capturePhoto(completion: @escaping (String?) -> Void) {
        pendingCompletion = completion
        let output = photoOutput
        let delegate = PhotoCaptureDelegate { [weak self] result in
            Task { @MainActor [weak self] in
                self?.pendingCompletion?(result)
                self?.pendingCompletion = nil
            }
        }
        sessionQueue.async {
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
    }
}

// MARK: - Private delegate (NSObject here, not in CameraManager)

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let handler: (String?) -> Void
    private var retainSelf: PhotoCaptureDelegate?

    init(handler: @escaping (String?) -> Void) {
        self.handler = handler
        super.init()
        retainSelf = self
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        retainSelf = nil
        guard
            error == nil,
            let data = photo.fileDataRepresentation(),
            let uiImage = UIImage(data: data),
            let jpegData = uiImage.jpegData(compressionQuality: 0.6)
        else {
            handler(nil)
            return
        }
        handler(jpegData.base64EncodedString())
    }
}

// MARK: - SwiftUI camera preview

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
