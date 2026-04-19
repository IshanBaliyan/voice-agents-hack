import SwiftUI
import RealityKit
import ARKit
import UIKit
import Vision
import Combine

/// SwiftUI wrapper around an ARView that renders a procedural training scene
/// (core object on a detected plane + hand-tracked tool pinned to the user's
/// wrist via Vision hand pose). Exposes a snapshot handle so the owning view
/// can capture the composited camera + 3D frame as a JPEG on demand.
struct EngineARView: UIViewRepresentable {
    let scenario: TrainingScenario
    final class Controller {
        weak var arView: ARView?

        // Hand-tracking state.
        fileprivate var wrenchAnchor: AnchorEntity?
        fileprivate var updateSub: Cancellable?
        fileprivate var isVisionBusy = false
        fileprivate var hasSmoothed = false
        fileprivate var smoothed = SIMD3<Float>(0, 0, 0)
        fileprivate var smoothedRot: simd_quatf?
        fileprivate let visionQueue = DispatchQueue(label: "hand.vision", qos: .userInitiated)
        fileprivate var framesSinceHit = 0

        func snapshotJPEG(completion: @escaping (URL?) -> Void) {
            guard let arView = arView else { completion(nil); return }
            arView.snapshot(saveToHDR: false) { image in
                guard let image = image, let data = image.jpegData(compressionQuality: 0.85) else {
                    completion(nil); return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("training-\(UUID().uuidString).jpg")
                do {
                    try data.write(to: url)
                    completion(url)
                } catch {
                    completion(nil)
                }
            }
        }
    }

    let controller: Controller

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero,
                            cameraMode: .ar,
                            automaticallyConfigureSession: false)
        arView.environment.background = .cameraFeed()

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        // People occlusion so the user's real hands render in front of the
        // virtual engine when they reach toward it.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        let anchor = AnchorEntity(plane: .horizontal,
                                  classification: .any,
                                  minimumBounds: [0.2, 0.2])
        anchor.addChild(scenario.makeCore())
        arView.scene.addAnchor(anchor)

        controller.arView = arView
        attachHandTracking(arView: arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }

    // MARK: - Hand-tracked tool

    private func attachHandTracking(arView: ARView) {
        let wrenchAnchor = AnchorEntity(world: .zero)
        wrenchAnchor.addChild(scenario.makeTool())
        wrenchAnchor.isEnabled = false
        arView.scene.addAnchor(wrenchAnchor)
        controller.wrenchAnchor = wrenchAnchor

        let ctrl = controller
        controller.updateSub = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak arView] _ in
            guard let arView = arView,
                  let frame = arView.session.currentFrame,
                  !ctrl.isVisionBusy else { return }
            ctrl.isVisionBusy = true
            let pixelBuffer = frame.capturedImage
            let bounds = arView.bounds

            ctrl.visionQueue.async {
                defer { DispatchQueue.main.async { ctrl.isVisionBusy = false } }

                let request = VNDetectHumanHandPoseRequest()
                request.maximumHandCount = 1
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                    orientation: .right,
                                                    options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    return
                }
                guard let observation = request.results?.first,
                      let wrist = try? observation.recognizedPoint(.wrist),
                      wrist.confidence > 0.35 else {
                    DispatchQueue.main.async { [weak arView] in
                        ctrl.framesSinceHit += 1
                        if ctrl.framesSinceHit > 8 {
                            ctrl.wrenchAnchor?.isEnabled = false
                            ctrl.hasSmoothed = false
                            ctrl.smoothedRot = nil
                        }
                        _ = arView
                    }
                    return
                }

                // Middle-finger MCP gives us a reliable second point along the hand
                // axis; together with the wrist it defines the hand's screen-space angle.
                let midMCP = try? observation.recognizedPoint(.middleMCP)

                // Vision hand-pose coords are normalized with origin at bottom-left
                // (in the image's native orientation). After .right rotation, x maps
                // to screen-x and y inverts to screen-y.
                let wristScreen = CGPoint(x: wrist.location.x * bounds.width,
                                          y: (1 - wrist.location.y) * bounds.height)
                let midScreen: CGPoint? = {
                    guard let m = midMCP, m.confidence > 0.25 else { return nil }
                    return CGPoint(x: m.location.x * bounds.width,
                                   y: (1 - m.location.y) * bounds.height)
                }()

                DispatchQueue.main.async { [weak arView] in
                    guard let arView = arView,
                          let ray = arView.ray(through: wristScreen) else { return }

                    // Depth proxy: hand size on screen shrinks with distance.
                    // Calibrated so a ~90px wrist→middleMCP maps to 0.35m; clamped
                    // to keep the wrench from snapping onto the lens or into infinity.
                    var rayDepth: Float = 0.35
                    if let mid = midScreen {
                        let pdx = Float(mid.x - wristScreen.x)
                        let pdy = Float(mid.y - wristScreen.y)
                        let pixelSize = sqrt(pdx * pdx + pdy * pdy)
                        if pixelSize > 8 {
                            let referencePx: Float = 90
                            let referenceDepth: Float = 0.35
                            rayDepth = max(0.15, min(0.9, referencePx * referenceDepth / pixelSize))
                        }
                    }

                    let target = ray.origin + ray.direction * rayDepth
                    if ctrl.hasSmoothed {
                        ctrl.smoothed = ctrl.smoothed * 0.7 + target * 0.3
                    } else {
                        ctrl.smoothed = target
                        ctrl.hasSmoothed = true
                    }
                    ctrl.framesSinceHit = 0
                    ctrl.wrenchAnchor?.isEnabled = true
                    ctrl.wrenchAnchor?.setPosition(ctrl.smoothed, relativeTo: nil)

                    // Orient wrench in the camera plane so its +X axis points along
                    // wrist → middle-MCP in screen space. 80/20: no depth tilt —
                    // wrench stays flat-on to the camera.
                    if let mid = midScreen {
                        let dx = Float(mid.x - wristScreen.x)
                        let dy = Float(mid.y - wristScreen.y)
                        if dx * dx + dy * dy > 16 { // ignore tiny hand sizes (<4px)
                            let theta = atan2(-dy, dx) // screen y is down-positive
                            let cam = arView.cameraTransform.matrix
                            let camRight = simd_normalize(SIMD3<Float>(cam.columns.0.x, cam.columns.0.y, cam.columns.0.z))
                            let camUp    = simd_normalize(SIMD3<Float>(cam.columns.1.x, cam.columns.1.y, cam.columns.1.z))
                            let camBack  = simd_normalize(SIMD3<Float>(cam.columns.2.x, cam.columns.2.y, cam.columns.2.z))

                            let xAxis = simd_normalize(cos(theta) * camRight + sin(theta) * camUp)
                            let zAxis = simd_normalize(simd_cross(xAxis, camBack))
                            let yAxis = simd_cross(zAxis, xAxis)
                            let basis = float3x3(xAxis, yAxis, zAxis)
                            let newRot = simd_quatf(basis)

                            if let prev = ctrl.smoothedRot {
                                ctrl.smoothedRot = simd_slerp(prev, newRot, 0.35)
                            } else {
                                ctrl.smoothedRot = newRot
                            }
                            if let rot = ctrl.smoothedRot {
                                ctrl.wrenchAnchor?.setOrientation(rot, relativeTo: nil)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Slow auto-rotate for visual interest

private struct AutorotateComponent: Component {
    var rate: Float = 0.15
}

private final class AutorotateSystem: RealityKit.System {
    private static let query = EntityQuery(where: .has(AutorotateComponent.self))
    required init(scene: RealityKit.Scene) {}
    func update(context: SceneUpdateContext) {
        context.scene.performQuery(Self.query).forEach { entity in
            guard let rate = entity.components[AutorotateComponent.self]?.rate else { return }
            let spin = simd_quatf(angle: rate * Float(context.deltaTime), axis: [0, 1, 0])
            entity.orientation = spin * entity.orientation
        }
    }
}

enum EngineARSystems {
    static func registerOnce() {
        struct Once { static let t: Void = {
            AutorotateComponent.registerComponent()
            AutorotateSystem.registerSystem()
        }() }
        _ = Once.t
    }
}
