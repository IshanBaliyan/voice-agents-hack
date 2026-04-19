import Foundation
import RealityKit
import UIKit
import simd

enum TrainingScenario {
    case battery
    case tire
    case sparkPlug

    func makeCore() -> Entity {
        switch self {
        case .battery:   return CarBatteryBuilder.make()
        case .tire:      return TireBuilder.make()
        case .sparkPlug: return EngineHeadBuilder.make()
        }
    }

    func makeTool() -> Entity {
        switch self {
        case .battery:   return JumperClampBuilder.make()
        case .tire:      return LugWrenchBuilder.make()
        case .sparkPlug: return SocketWrenchBuilder.make()
        }
    }
}

// MARK: - Battery + jumper clamp

private enum CarBatteryBuilder {
    static func make() -> Entity {
        let e = Entity()
        let caseBody = SimpleMaterial(color: .init(white: 0.09, alpha: 1.0), roughness: 0.80, isMetallic: false)
        let caseTop  = SimpleMaterial(color: .init(white: 0.17, alpha: 1.0), roughness: 0.70, isMetallic: false)
        let label    = SimpleMaterial(color: .init(red: 0.92, green: 0.78, blue: 0.18, alpha: 1.0),
                                      roughness: 0.55, isMetallic: false)
        let lead     = SimpleMaterial(color: .init(white: 0.58, alpha: 1.0), roughness: 0.28, isMetallic: true)
        let redPlastic   = SimpleMaterial(color: .init(red: 0.86, green: 0.13, blue: 0.13, alpha: 1.0),
                                          roughness: 0.45, isMetallic: false)
        let blackPlastic = SimpleMaterial(color: .init(white: 0.06, alpha: 1.0), roughness: 0.55, isMetallic: false)

        let body = ModelEntity(mesh: .generateBox(size: [0.26, 0.17, 0.175], cornerRadius: 0.008),
                               materials: [caseBody])
        body.position = [0, 0.085, 0]
        e.addChild(body)

        let lid = ModelEntity(mesh: .generateBox(size: [0.262, 0.016, 0.177], cornerRadius: 0.004),
                              materials: [caseTop])
        lid.position = [0, 0.178, 0]
        e.addChild(lid)

        // Carry handle slot (two flanking ridges suggest a recessed handle).
        let handleL = ModelEntity(mesh: .generateBox(size: [0.004, 0.010, 0.090], cornerRadius: 0.001),
                                  materials: [caseBody])
        handleL.position = [-0.050, 0.188, 0]
        e.addChild(handleL)
        let handleR = ModelEntity(mesh: .generateBox(size: [0.004, 0.010, 0.090], cornerRadius: 0.001),
                                  materials: [caseBody])
        handleR.position = [0.050, 0.188, 0]
        e.addChild(handleR)

        // Yellow brand-ish label on the long side.
        let sticker = ModelEntity(mesh: .generateBox(size: [0.14, 0.070, 0.002], cornerRadius: 0.004),
                                  materials: [label])
        sticker.position = [0, 0.095, 0.089]
        e.addChild(sticker)

        // 6 vent caps (2 rows × 3 columns) flanking the handle slot.
        for row in 0..<2 {
            for col in 0..<3 {
                let cap = ModelEntity(mesh: .generateCylinder(height: 0.008, radius: 0.013),
                                      materials: [caseBody])
                let x = Float(col - 1) * 0.060
                let z = Float(row == 0 ? -0.055 : 0.055)
                cap.position = [x, 0.190, z]
                e.addChild(cap)
            }
        }

        // Terminal posts, red (+) and black (−) on either side, with tapered collars.
        func addPost(x: Float, collar: SimpleMaterial) {
            let base = ModelEntity(mesh: .generateCylinder(height: 0.006, radius: 0.030),
                                   materials: [collar])
            base.position = [x, 0.189, -0.060]
            e.addChild(base)

            let collarMid = ModelEntity(mesh: .generateCylinder(height: 0.010, radius: 0.024),
                                        materials: [collar])
            collarMid.position = [x, 0.197, -0.060]
            e.addChild(collarMid)

            let post = ModelEntity(mesh: .generateCylinder(height: 0.022, radius: 0.013),
                                   materials: [lead])
            post.position = [x, 0.213, -0.060]
            e.addChild(post)
        }
        addPost(x: 0.080, collar: redPlastic)
        addPost(x: -0.080, collar: blackPlastic)

        // "+" and "−" signage next to each post.
        let plusH = ModelEntity(mesh: .generateBox(size: [0.024, 0.003, 0.006], cornerRadius: 0.001),
                                materials: [redPlastic])
        plusH.position = [0.080, 0.187, -0.018]
        e.addChild(plusH)
        let plusV = ModelEntity(mesh: .generateBox(size: [0.006, 0.003, 0.024], cornerRadius: 0.001),
                                materials: [redPlastic])
        plusV.position = [0.080, 0.187, -0.018]
        e.addChild(plusV)

        let minusBar = ModelEntity(mesh: .generateBox(size: [0.024, 0.003, 0.006], cornerRadius: 0.001),
                                   materials: [blackPlastic])
        minusBar.position = [-0.080, 0.187, -0.018]
        e.addChild(minusBar)

        return e
    }
}

private enum JumperClampBuilder {
    static func make() -> Entity {
        // Hand is at local origin and holds the cable. The cable extends +X
        // forward, enters the clamp body, and the clamp jaws are at the far tip.
        let e = Entity()
        let redGrip   = SimpleMaterial(color: .init(red: 0.82, green: 0.12, blue: 0.12, alpha: 1.0),
                                       roughness: 0.55, isMetallic: false)
        let metal     = SimpleMaterial(color: .init(white: 0.78, alpha: 1.0), roughness: 0.22, isMetallic: true)
        let darkMetal = SimpleMaterial(color: .init(white: 0.32, alpha: 1.0), roughness: 0.35, isMetallic: true)
        let cableRed  = SimpleMaterial(color: .init(red: 0.66, green: 0.09, blue: 0.09, alpha: 1.0),
                                       roughness: 0.75, isMetallic: false)

        // Thin red cable from hand → clamp body.
        let cableLen: Float = 0.11
        let cable = ModelEntity(mesh: .generateCylinder(height: cableLen, radius: 0.006),
                                materials: [cableRed])
        cable.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        cable.position = [cableLen / 2, 0, 0]
        e.addChild(cable)

        // Strain-relief boot where the cable enters the clamp.
        let boot = ModelEntity(mesh: .generateCylinder(height: 0.016, radius: 0.012),
                               materials: [darkMetal])
        boot.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        boot.position = [cableLen + 0.008, 0, 0]
        e.addChild(boot)

        // Red handle grips (top + bottom) behind the pivot.
        let gripStart: Float = cableLen + 0.018  // 0.128
        let gripLen:   Float = 0.060
        let gripCenterX = gripStart + gripLen / 2
        let topGrip = ModelEntity(mesh: .generateBox(size: [gripLen, 0.022, 0.028], cornerRadius: 0.006),
                                  materials: [redGrip])
        topGrip.position = [gripCenterX, 0.020, 0]
        e.addChild(topGrip)
        let bottomGrip = ModelEntity(mesh: .generateBox(size: [gripLen, 0.022, 0.028], cornerRadius: 0.006),
                                     materials: [redGrip])
        bottomGrip.position = [gripCenterX, -0.020, 0]
        e.addChild(bottomGrip)

        // Grip grooves.
        for i in 0..<3 {
            let x = gripCenterX + Float(i - 1) * 0.018
            let grooveT = ModelEntity(mesh: .generateBox(size: [0.003, 0.004, 0.030], cornerRadius: 0.0008),
                                      materials: [darkMetal])
            grooveT.position = [x, 0.030, 0]
            e.addChild(grooveT)
            let grooveB = ModelEntity(mesh: .generateBox(size: [0.003, 0.004, 0.030], cornerRadius: 0.0008),
                                      materials: [darkMetal])
            grooveB.position = [x, -0.030, 0]
            e.addChild(grooveB)
        }

        // Hinge pivot at end of the grips.
        let pivotX: Float = gripStart + gripLen + 0.004
        let pivot = ModelEntity(mesh: .generateCylinder(height: 0.034, radius: 0.005),
                                materials: [darkMetal])
        pivot.position = [pivotX, 0, 0]
        pivot.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        e.addChild(pivot)

        // Upper + lower jaws, angled so the mouth is slightly open at the tip.
        let jawAngle: Float = .pi / 26
        let jawLen:   Float = 0.090
        let jawMid:   Float = pivotX + jawLen / 2
        let upperJaw = ModelEntity(mesh: .generateBox(size: [jawLen, 0.010, 0.022], cornerRadius: 0.002),
                                   materials: [metal])
        upperJaw.position = [jawMid, 0.008 + jawLen / 2 * sin(jawAngle), 0]
        upperJaw.orientation = simd_quatf(angle: -jawAngle, axis: [0, 0, 1])
        e.addChild(upperJaw)

        let lowerJaw = ModelEntity(mesh: .generateBox(size: [jawLen, 0.010, 0.022], cornerRadius: 0.002),
                                   materials: [metal])
        lowerJaw.position = [jawMid, -0.008 - jawLen / 2 * sin(jawAngle), 0]
        lowerJaw.orientation = simd_quatf(angle: jawAngle, axis: [0, 0, 1])
        e.addChild(lowerJaw)

        // Interlocking teeth along each inner jaw edge.
        let toothStart: Float = pivotX + 0.042
        for i in 0..<4 {
            let xPos = toothStart + Float(i) * 0.012
            let tUp = ModelEntity(mesh: .generateBox(size: [0.006, 0.010, 0.020], cornerRadius: 0.001),
                                  materials: [darkMetal])
            tUp.position = [xPos, 0.004, 0]
            e.addChild(tUp)
            let tDown = ModelEntity(mesh: .generateBox(size: [0.006, 0.010, 0.020], cornerRadius: 0.001),
                                    materials: [darkMetal])
            tDown.position = [xPos + 0.006, -0.004, 0]
            e.addChild(tDown)
        }

        return e
    }
}

// MARK: - Wheel + cross lug wrench

private enum TireBuilder {
    static func make() -> Entity {
        let e = Entity()
        let rubber   = SimpleMaterial(color: .init(white: 0.05, alpha: 1.0), roughness: 0.96, isMetallic: false)
        let sidewall = SimpleMaterial(color: .init(white: 0.10, alpha: 1.0), roughness: 0.85, isMetallic: false)
        let rim      = SimpleMaterial(color: .init(white: 0.70, alpha: 1.0), roughness: 0.30, isMetallic: true)
        let rimDark  = SimpleMaterial(color: .init(white: 0.50, alpha: 1.0), roughness: 0.38, isMetallic: true)
        let hub      = SimpleMaterial(color: .init(white: 0.42, alpha: 1.0), roughness: 0.35, isMetallic: true)
        let chrome   = SimpleMaterial(color: .init(white: 0.92, alpha: 1.0), roughness: 0.15, isMetallic: true)
        let tread    = SimpleMaterial(color: .init(white: 0.03, alpha: 1.0), roughness: 0.98, isMetallic: false)

        let tireHeight: Float = 0.11
        let tireRadius: Float = 0.235

        // Main rubber carcass.
        let outer = ModelEntity(mesh: .generateCylinder(height: tireHeight, radius: tireRadius),
                                materials: [rubber])
        outer.position = [0, tireHeight / 2, 0]
        e.addChild(outer)

        // Sidewall ring (just visible lip where rubber meets rim).
        let sideTop = ModelEntity(mesh: .generateCylinder(height: 0.002, radius: tireRadius - 0.008),
                                  materials: [sidewall])
        sideTop.position = [0, tireHeight + 0.001, 0]
        e.addChild(sideTop)

        // Tread blocks around the outside.
        let blocks = 26
        for k in 0..<blocks {
            let angle = Float(k) * 2 * .pi / Float(blocks)
            let block = ModelEntity(mesh: .generateBox(size: [0.024, tireHeight - 0.008, 0.046],
                                                       cornerRadius: 0.002),
                                    materials: [tread])
            let r = tireRadius + 0.003
            block.position = [r * cos(angle), tireHeight / 2, r * sin(angle)]
            block.orientation = simd_quatf(angle: -angle, axis: [0, 1, 0])
            e.addChild(block)
        }

        // Rim face (inset so it sits slightly below the sidewall top).
        let rimFace = ModelEntity(mesh: .generateCylinder(height: 0.016, radius: 0.180),
                                  materials: [rim])
        rimFace.position = [0, tireHeight - 0.004, 0]
        e.addChild(rimFace)

        // Rim outer ring (bevel between face and sidewall).
        let rimRing = ModelEntity(mesh: .generateCylinder(height: 0.010, radius: 0.200),
                                  materials: [rimDark])
        rimRing.position = [0, tireHeight - 0.001, 0]
        e.addChild(rimRing)

        // Hub center.
        let centerHub = ModelEntity(mesh: .generateCylinder(height: 0.028, radius: 0.048),
                                    materials: [hub])
        centerHub.position = [0, tireHeight + 0.014, 0]
        e.addChild(centerHub)

        // 5 spokes radiating from hub to rim.
        for k in 0..<5 {
            let angle = Float(k) * 2 * .pi / 5
            let spoke = ModelEntity(mesh: .generateBox(size: [0.130, 0.014, 0.034], cornerRadius: 0.003),
                                    materials: [rim])
            let midR: Float = 0.105
            spoke.position = [midR * cos(angle), tireHeight + 0.003, midR * sin(angle)]
            spoke.orientation = simd_quatf(angle: -angle, axis: [0, 1, 0])
            e.addChild(spoke)
        }

        // 5 chrome lug nuts arranged between spokes.
        for k in 0..<5 {
            let angle = Float(k) * 2 * .pi / 5 + .pi / 5
            let lug = ModelEntity(mesh: .generateCylinder(height: 0.028, radius: 0.018),
                                  materials: [chrome])
            let r: Float = 0.082
            lug.position = [r * cos(angle), tireHeight + 0.018, r * sin(angle)]
            e.addChild(lug)
            // Hex-ish base ring under each lug.
            let washer = ModelEntity(mesh: .generateCylinder(height: 0.004, radius: 0.022),
                                     materials: [rimDark])
            washer.position = [r * cos(angle), tireHeight + 0.006, r * sin(angle)]
            e.addChild(washer)
        }

        // Center logo cap.
        let logo = ModelEntity(mesh: .generateCylinder(height: 0.006, radius: 0.022),
                               materials: [chrome])
        logo.position = [0, tireHeight + 0.031, 0]
        e.addChild(logo)

        // Stand the wheel up: axis goes from +Y to +Z, then lift so it sits on the plane.
        e.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        e.position = [0, tireRadius, 0]
        return e
    }
}

private enum LugWrenchBuilder {
    static func make() -> Entity {
        // Classic L-shape tire iron: long chrome handle in the hand, 90° bend
        // at the tip, short perpendicular arm ending in a socket.
        let e = Entity()
        let chrome    = SimpleMaterial(color: .init(white: 0.92, alpha: 1.0), roughness: 0.14, isMetallic: true)
        let darkSteel = SimpleMaterial(color: .init(white: 0.35, alpha: 1.0), roughness: 0.30, isMetallic: true)
        let rubber    = SimpleMaterial(color: .init(white: 0.05, alpha: 1.0), roughness: 0.92, isMetallic: false)
        let hexHole   = SimpleMaterial(color: .black, isMetallic: false)

        let handleLen: Float = 0.26
        // Main handle along +X.
        let handle = ModelEntity(mesh: .generateBox(size: [handleLen, 0.018, 0.020], cornerRadius: 0.004),
                                 materials: [chrome])
        handle.position = [handleLen / 2, 0, 0]
        e.addChild(handle)

        // Rubber grip near the hand.
        let grip = ModelEntity(mesh: .generateBox(size: [0.074, 0.024, 0.030], cornerRadius: 0.006),
                               materials: [rubber])
        grip.position = [0.045, 0, 0]
        e.addChild(grip)

        // Grip ridges.
        for i in 0..<4 {
            let x = 0.018 + Float(i) * 0.018
            let ridge = ModelEntity(mesh: .generateBox(size: [0.003, 0.026, 0.032], cornerRadius: 0.0008),
                                    materials: [darkSteel])
            ridge.position = [x, 0, 0]
            e.addChild(ridge)
        }

        // Flat pry tip at the -X end (classic hubcap remover).
        let pry = ModelEntity(mesh: .generateBox(size: [0.024, 0.008, 0.020], cornerRadius: 0.002),
                              materials: [darkSteel])
        pry.position = [-0.012, 0, 0]
        e.addChild(pry)

        // 90° corner block at the +X tip of the handle.
        let elbow = ModelEntity(mesh: .generateBox(size: [0.024, 0.024, 0.024], cornerRadius: 0.005),
                                materials: [chrome])
        elbow.position = [handleLen + 0.002, 0, -0.012]
        e.addChild(elbow)

        // Perpendicular arm going -Z from the elbow (in the screen plane).
        let armLen: Float = 0.085
        let arm = ModelEntity(mesh: .generateBox(size: [0.020, 0.020, armLen], cornerRadius: 0.003),
                              materials: [chrome])
        arm.position = [handleLen + 0.002, 0, -(0.024 + armLen / 2)]
        e.addChild(arm)

        // Socket at the end of the perpendicular arm, axis along Z.
        let socket = ModelEntity(mesh: .generateCylinder(height: 0.030, radius: 0.024),
                                 materials: [darkSteel])
        socket.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        socket.position = [handleLen + 0.002, 0, -(0.024 + armLen + 0.015)]
        e.addChild(socket)

        // Outer chrome bevel ring on the socket face.
        let socketRing = ModelEntity(mesh: .generateCylinder(height: 0.008, radius: 0.028),
                                     materials: [chrome])
        socketRing.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        socketRing.position = [handleLen + 0.002, 0, -(0.024 + armLen + 0.027)]
        e.addChild(socketRing)

        // Dark hex bore visible at the socket face.
        let bore = ModelEntity(mesh: .generateCylinder(height: 0.003, radius: 0.014),
                               materials: [hexHole])
        bore.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        bore.position = [handleLen + 0.002, 0, -(0.024 + armLen + 0.033)]
        e.addChild(bore)

        return e
    }
}

// MARK: - Engine head + ratchet socket wrench

private enum EngineHeadBuilder {
    static func make() -> Entity {
        // Clean inline-4 valve cover with four exposed spark plugs lined up
        // down the center — no coil boots or wires to distract from the plugs.
        let e = Entity()
        let aluminum = SimpleMaterial(color: .init(white: 0.63, alpha: 1.0), roughness: 0.50, isMetallic: true)
        let darkAlum = SimpleMaterial(color: .init(white: 0.42, alpha: 1.0), roughness: 0.55, isMetallic: true)
        let boot     = SimpleMaterial(color: .init(white: 0.05, alpha: 1.0), roughness: 0.95, isMetallic: false)
        let ceramic  = SimpleMaterial(color: .init(white: 0.94, alpha: 1.0), roughness: 0.45, isMetallic: false)
        let plugHex  = SimpleMaterial(color: .init(white: 0.55, alpha: 1.0), roughness: 0.30, isMetallic: true)

        // Valve cover body.
        let body = ModelEntity(mesh: .generateBox(size: [0.38, 0.08, 0.16], cornerRadius: 0.012),
                               materials: [aluminum])
        body.position = [0, 0.04, 0]
        e.addChild(body)

        // Three longitudinal ribs running lengthwise.
        for z in [Float(-0.046), 0.0, 0.046] {
            let ridge = ModelEntity(mesh: .generateBox(size: [0.36, 0.010, 0.012], cornerRadius: 0.002),
                                    materials: [darkAlum])
            ridge.position = [0, 0.085, z]
            e.addChild(ridge)
        }

        // 6 perimeter bolt heads.
        let boltXs: [Float] = [-0.165, 0.0, 0.165]
        let boltZs: [Float] = [-0.065, 0.065]
        for x in boltXs {
            for z in boltZs {
                let bolt = ModelEntity(mesh: .generateCylinder(height: 0.010, radius: 0.010),
                                       materials: [darkAlum])
                bolt.position = [x, 0.086, z]
                e.addChild(bolt)
            }
        }

        // Four exposed spark plugs running down the center of the head.
        let wellX: [Float] = [-0.130, -0.045, 0.045, 0.130]
        for x in wellX {
            // Rubber boot seal ring around the base.
            let collar = ModelEntity(mesh: .generateCylinder(height: 0.010, radius: 0.028),
                                     materials: [boot])
            collar.position = [x, 0.085, 0]
            e.addChild(collar)

            // Hex nut base of the plug.
            let hex = ModelEntity(mesh: .generateCylinder(height: 0.016, radius: 0.019),
                                  materials: [plugHex])
            hex.position = [x, 0.098, 0]
            e.addChild(hex)

            // White ceramic insulator, stepped (wider base, narrower top).
            let ceramicLower = ModelEntity(mesh: .generateCylinder(height: 0.028, radius: 0.014),
                                           materials: [ceramic])
            ceramicLower.position = [x, 0.120, 0]
            e.addChild(ceramicLower)
            let ceramicUpper = ModelEntity(mesh: .generateCylinder(height: 0.038, radius: 0.010),
                                           materials: [ceramic])
            ceramicUpper.position = [x, 0.153, 0]
            e.addChild(ceramicUpper)

            // Metal terminal stud on top.
            let terminal = ModelEntity(mesh: .generateCylinder(height: 0.010, radius: 0.007),
                                       materials: [plugHex])
            terminal.position = [x, 0.177, 0]
            e.addChild(terminal)
        }

        return e
    }
}

private enum SocketWrenchBuilder {
    static func make() -> Entity {
        let e = Entity()
        let chrome    = SimpleMaterial(color: .init(white: 0.92, alpha: 1.0), roughness: 0.14, isMetallic: true)
        let darkSteel = SimpleMaterial(color: .init(white: 0.35, alpha: 1.0), roughness: 0.32, isMetallic: true)
        let rubber    = SimpleMaterial(color: .init(white: 0.05, alpha: 1.0), roughness: 0.92, isMetallic: false)
        let hexHole   = SimpleMaterial(color: .black, isMetallic: false)

        // Polished chrome handle shaft.
        let handle = ModelEntity(mesh: .generateBox(size: [0.17, 0.012, 0.020], cornerRadius: 0.003),
                                 materials: [chrome])
        handle.position = [0.080, 0, 0]
        e.addChild(handle)

        // Rubber overmold in the grip zone.
        let grip = ModelEntity(mesh: .generateBox(size: [0.090, 0.020, 0.030], cornerRadius: 0.006),
                               materials: [rubber])
        grip.position = [0.055, 0, 0]
        e.addChild(grip)

        // 5 grip ridges.
        for i in 0..<5 {
            let x = 0.022 + Float(i) * 0.016
            let ridge = ModelEntity(mesh: .generateBox(size: [0.003, 0.022, 0.032], cornerRadius: 0.0008),
                                    materials: [darkSteel])
            ridge.position = [x, 0, 0]
            e.addChild(ridge)
        }

        // End cap (butt of handle).
        let butt = ModelEntity(mesh: .generateBox(size: [0.012, 0.018, 0.024], cornerRadius: 0.003),
                               materials: [darkSteel])
        butt.position = [-0.004, 0, 0]
        e.addChild(butt)

        // Ratchet head disk (axis along local Y, i.e., face toward camera).
        let head = ModelEntity(mesh: .generateCylinder(height: 0.018, radius: 0.032),
                               materials: [chrome])
        head.position = [0.184, 0, 0]
        e.addChild(head)

        // Outer dark ring on the head rim.
        let headRing = ModelEntity(mesh: .generateCylinder(height: 0.008, radius: 0.034),
                                   materials: [darkSteel])
        headRing.position = [0.184, 0.003, 0]
        e.addChild(headRing)

        // Direction reverse knob on top of the head.
        let knob = ModelEntity(mesh: .generateCylinder(height: 0.008, radius: 0.008),
                               materials: [darkSteel])
        knob.position = [0.184, 0.013, 0]
        e.addChild(knob)

        // Square drive + socket extending into the scene (−Y, away from viewer).
        let drive = ModelEntity(mesh: .generateBox(size: [0.012, 0.014, 0.012], cornerRadius: 0.001),
                                materials: [darkSteel])
        drive.position = [0.184, -0.016, 0]
        e.addChild(drive)

        let socket = ModelEntity(mesh: .generateCylinder(height: 0.028, radius: 0.020),
                                 materials: [darkSteel])
        socket.position = [0.184, -0.037, 0]
        e.addChild(socket)

        // Darker hex bore visible at the end of the socket.
        let bore = ModelEntity(mesh: .generateCylinder(height: 0.003, radius: 0.013),
                               materials: [hexHole])
        bore.position = [0.184, -0.052, 0]
        e.addChild(bore)

        return e
    }
}
