import Foundation
import AVFoundation
import Combine

@MainActor
final class CameraCapture: NSObject, ObservableObject {
    @Published var permissionDenied: Bool = false

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private var delegate: PhotoDelegate?
    private var configured = false

    func start() async throws {
        let granted = await requestCameraPermission()
        if !granted {
            permissionDenied = true
            throw NSError(domain: "CameraCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Camera permission denied."])
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func capture() async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            sessionQueue.async { [weak self] in
                guard let self, self.session.isRunning else {
                    cont.resume(returning: nil); return
                }
                // Force JPEG. Default AVCapturePhotoSettings produces HEIC on modern iPhones,
                // but Cactus's vision encoder uses stb_image which can't decode HEIC — it would
                // throw during prefill and kill the completion with an empty error string.
                let jpegSupported = self.photoOutput.availablePhotoCodecTypes.contains(.jpeg)
                let settings: AVCapturePhotoSettings = jpegSupported
                    ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                    : AVCapturePhotoSettings()
                let handler = PhotoDelegate { url in
                    Task { @MainActor in self.delegate = nil }
                    cont.resume(returning: url)
                }
                Task { @MainActor in self.delegate = handler }
                self.photoOutput.capturePhoto(with: settings, delegate: handler)
            }
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        session.beginConfiguration()
        // 1080p preset keeps capture fast + the JPEG small enough for Gemma's vision encoder.
        // .photo triggers 12+ MP captures that can OOM the model.
        session.sessionPreset = .hd1920x1080
        // We manage AVAudioSession ourselves for mic recording. If the capture session
        // also configures it, the two race and the audio I/O thread crashes on device.
        session.automaticallyConfiguresApplicationAudioSession = false

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            session.commitConfiguration()
            throw NSError(domain: "CameraCapture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Rear camera unavailable."])
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw error
        }

        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        session.commitConfiguration()
        configured = true
    }

    private func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let onFinish: (URL?) -> Void
    init(onFinish: @escaping (URL?) -> Void) { self.onFinish = onFinish }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            onFinish(nil); return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
            onFinish(url)
        } catch {
            onFinish(nil)
        }
    }
}
