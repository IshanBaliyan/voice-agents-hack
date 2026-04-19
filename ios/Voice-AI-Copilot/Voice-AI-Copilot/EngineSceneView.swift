import SwiftUI
import SceneKit

struct EngineSceneView: UIViewRepresentable {
    let modelResource: String
    var highlightedNodeName: String?
    var isExploded: Bool = false
    var onTap: (String) -> Void

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false

        if let scene = Self.loadScene(resource: modelResource) {
            view.scene = scene
            Self.frameCamera(view: view, scene: scene)
            context.coordinator.cacheParts(in: scene)
        }

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tap)
        context.coordinator.sceneView = view
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.applyHighlight(nodeName: highlightedNodeName, in: view.scene)
        context.coordinator.applyExplosion(isExploded)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    // MARK: - Scene loading

    private static func loadScene(resource: String) -> SCNScene? {
        let url = Bundle.main.url(forResource: resource, withExtension: "usdz")
            ?? Bundle.main.url(forResource: resource, withExtension: "usdz", subdirectory: "EngineAssets")
        guard let url else {
            print("EngineSceneView: missing \(resource).usdz in bundle")
            return nil
        }
        do {
            let scene = try SCNScene(url: url, options: [
                .createNormalsIfAbsent: true,
                .checkConsistency: false,
            ])
            scene.background.contents = UIColor.black
            return scene
        } catch {
            print("EngineSceneView: failed to load scene: \(error)")
            return nil
        }
    }

    private static func frameCamera(view: SCNView, scene: SCNScene) {
        let (minVec, maxVec) = scene.rootNode.boundingBox
        let center = SCNVector3(
            (minVec.x + maxVec.x) * 0.5,
            (minVec.y + maxVec.y) * 0.5,
            (minVec.z + maxVec.z) * 0.5
        )
        let extent = max(
            maxVec.x - minVec.x,
            maxVec.y - minVec.y,
            maxVec.z - minVec.z
        )
        let distance = Float(extent) * 2.2

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 55
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = Double(distance * 10)
        cameraNode.position = SCNVector3(center.x, center.y + extent * 0.15, center.z + distance)
        cameraNode.look(at: center)
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var onTap: (String) -> Void
        weak var sceneView: SCNView?

        private var highlightedNode: SCNNode?
        private var originalEmissions: [SCNMaterial: Any?] = [:]

        private var partCache: [(node: SCNNode, origin: SCNVector3, direction: SCNVector3)] = []
        private var explosionExtent: Float = 1.0
        private var currentlyExploded: Bool = false

        init(onTap: @escaping (String) -> Void) {
            self.onTap = onTap
        }

        func cacheParts(in scene: SCNScene) {
            partCache.removeAll()
            let (minV, maxV) = scene.rootNode.boundingBox
            let center = SCNVector3(
                (minV.x + maxV.x) * 0.5,
                (minV.y + maxV.y) * 0.5,
                (minV.z + maxV.z) * 0.5
            )
            explosionExtent = max(
                Float(maxV.x - minV.x),
                Float(maxV.y - minV.y),
                Float(maxV.z - minV.z)
            )

            scene.rootNode.enumerateHierarchy { node, _ in
                guard node.geometry != nil,
                      let name = node.name, !name.isEmpty
                else { return }

                let world = node.worldPosition
                let dx = Float(world.x - center.x)
                let dy = Float(world.y - center.y)
                let dz = Float(world.z - center.z)
                let len = sqrt(dx * dx + dy * dy + dz * dz)
                let worldDir: SCNVector3 = len > 0.0001
                    ? SCNVector3(dx / len, dy / len, dz / len)
                    : SCNVector3(0, 1, 0)

                let parent = node.parent ?? scene.rootNode
                let localDir = parent.convertVector(worldDir, from: nil)
                partCache.append((node, node.position, localDir))
            }
        }

        func applyExplosion(_ exploded: Bool) {
            guard exploded != currentlyExploded, !partCache.isEmpty else {
                currentlyExploded = exploded
                return
            }
            currentlyExploded = exploded
            let factor: Float = exploded ? explosionExtent * 0.48 : 0
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.55
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for entry in partCache {
                entry.node.position = SCNVector3(
                    entry.origin.x + entry.direction.x * factor,
                    entry.origin.y + entry.direction.y * factor,
                    entry.origin.z + entry.direction.z * factor
                )
            }
            SCNTransaction.commit()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = sceneView else { return }
            let location = gesture.location(in: view)
            let hits = view.hitTest(location, options: [
                SCNHitTestOption.backFaceCulling: true,
                SCNHitTestOption.boundingBoxOnly: false,
                SCNHitTestOption.ignoreHiddenNodes: true,
            ])
            guard let first = hits.first else { return }

            // Walk up the node chain to find a name that looks like a part id.
            var node: SCNNode? = first.node
            while let current = node {
                if let name = current.name, !name.isEmpty {
                    onTap(name)
                    return
                }
                node = current.parent
            }
        }

        func applyHighlight(nodeName: String?, in scene: SCNScene?) {
            // Clear previous highlight.
            for (material, original) in originalEmissions {
                material.emission.contents = original ?? UIColor.black
            }
            originalEmissions.removeAll()
            highlightedNode = nil

            guard
                let nodeName,
                let root = scene?.rootNode,
                let target = root.childNode(withName: nodeName, recursively: true)
            else { return }

            highlightedNode = target
            let tint = UIColor(red: 0.114, green: 0.725, blue: 0.329, alpha: 1.0)
            target.enumerateHierarchy { child, _ in
                guard let geometry = child.geometry else { return }
                for material in geometry.materials {
                    originalEmissions[material] = material.emission.contents
                    material.emission.contents = tint
                }
            }
        }
    }
}
