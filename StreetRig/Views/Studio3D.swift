//
//  Studio3D.swift
//  StreetRig
//
//  Shared SceneKit scaffolding for the app's 3D gear models (amp, pedals,
//  guitar). One place for PBR materials, studio lighting + a generated
//  image-based environment, camera framing, a cheap contact shadow, and the
//  knob-angle math — so every 3D model is lit, shaded, and grounded the same
//  way. Used by AmpModel3DView, PedalboardModel3DView, and GuitarModel3DView.
//

import SceneKit
import UIKit

enum Studio3D {

    // MARK: - PBR material

    static func pbr(_ color: UIColor, metalness: CGFloat, roughness: CGFloat,
                    emission: UIColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metalness
        m.roughness.contents = roughness
        if let emission { m.emission.contents = emission }
        return m
    }

    // MARK: - Lighting (key + fill + ambient + image-based environment)

    /// The one light rig, shared by the diorama and all three detail views.
    ///
    /// WARM AND BRIGHT on purpose. The numbers below used to describe a cool studio:
    /// a 5900 K key against a 6800 K fill and a 7400 K rim, over an ambient of 85. On
    /// a bare turntable that reads as clean product lighting, but once the gear stood
    /// in a modelled room the same rig lit it like a morgue — the wooden boards went
    /// grey-blue, and with almost no ambient everything the key missed fell to black,
    /// so the "room" was a lit disc floating in a void.
    ///
    /// Every colour temperature has come DOWN (lower is warmer: 4200 K is a stage
    /// lamp, 7400 K was overcast daylight) and the ambient is up more than fivefold,
    /// which is what actually makes a room feel lit rather than spotlit. Shadows are
    /// lightened to match — a bright room does not throw near-black ones.
    ///
    /// `envIntensity` moves the least of anything here, and deliberately. Image-based
    /// lighting compounds with the ambient rather than adding to it, so lifting both
    /// hard blows out the faceplates; the ambient is the honest lever for "is the room
    /// lit", and this stays a nudge.
    ///
    /// Kept shared rather than given the stage its own rig, deliberately: tapping a
    /// pedal flies the camera from the diorama to that pedal, and if the two rigs
    /// disagreed the piece would visibly change colour on the way in.
    static func addLighting(to scene: SCNScene, keyIntensity: CGFloat = 1300,
                            envIntensity: CGFloat = 1.5) {
        scene.lightingEnvironment.contents = environmentImage()   // IBL for PBR reflections
        scene.lightingEnvironment.intensity = envIntensity

        let key = SCNLight()
        key.type = .directional
        key.intensity = keyIntensity
        key.temperature = 4200                                  // stage lamp, not daylight
        key.castsShadow = true                                  // real directional contact shadow…
        key.shadowMode = .forward
        key.shadowRadius = 8                                    // …softened with PCF so it's a gentle grounding
        key.shadowSampleCount = 16
        key.shadowColor = UIColor(white: 0, alpha: 0.30)        // lighter, to match the brighter room
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.9, 0.5, 0)          // upper front-left
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 620
        fill.temperature = 5000
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(-0.25, -0.9, 0)       // soft right fill
        scene.rootNode.addChildNode(fillNode)

        // Rim light from behind-above for edge separation. Still the coolest of the
        // three — that contrast is what keeps a warm room from turning into soup —
        // but no longer the icy 7400 K that was outlining everything in blue.
        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 560
        rim.temperature = 6000
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.eulerAngles = SCNVector3(0.6, 3.0, 0)
        scene.rootNode.addChildNode(rimNode)

        // The room light. This is the single biggest lever on "does this feel like a
        // lit space?", because it is the only one that reaches surfaces no directional
        // light is aimed at — the far side of the amp, under the stool, the boards
        // behind the rig. At 85 those were all but black.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 460
        ambient.temperature = 4500                              // warm bounce, as off wood
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
    }

    // MARK: - Camera

    @discardableResult
    static func addCamera(to scene: SCNScene, position: SCNVector3,
                          tilt: Float = 0, fov: CGFloat = 34) -> SCNNode {
        let cam = SCNCamera()
        cam.fieldOfView = fov
        cam.wantsHDR = true
        cam.wantsExposureAdaptation = false                     // no brightness pumping as the camera moves
        cam.zNear = 0.05
        cam.zFar = 200
        // Cinematic grade — all built-in SCNCamera post: a gentle bloom so LEDs and
        // metal highlights glow, a soft vignette to focus the eye on the rig, and a
        // touch of saturation/contrast for punch. Subtle enough to also flatter the
        // amp/pedal detail views that share this camera.
        cam.bloomIntensity = 0.55
        cam.bloomThreshold = 0.82
        cam.bloomBlurRadius = 14
        cam.vignettingIntensity = 0.45
        cam.vignettingPower = 1.5
        cam.saturation = 1.08
        cam.contrast = 0.08
        let node = SCNNode()
        node.camera = cam
        node.name = "camera"
        node.position = position
        node.eulerAngles = SCNVector3(tilt, 0, 0)               // pitch only
        scene.rootNode.addChildNode(node)
        return node
    }

    // MARK: - Contact shadow

    /// A cheap fake contact shadow — a flat radial-gradient plane on the floor —
    /// so a model reads as grounded without a shadow-casting light setup.
    ///
    /// FOR THE ISOLATED DETAIL VIEWS ONLY (`AmpModel3DView`, `PedalModel3DView`,
    /// `GuitarModel3DView`). Those scenes place a model against an empty background:
    /// they have a `floorY` coordinate but no floor geometry, so the key light's cast
    /// shadow has nothing to land on and this blob is the only thing grounding them.
    ///
    /// DO NOT call it from `RigStage3DView`. That scene has a real floor which
    /// `StageEnvironment` is set up to receive a real shadow on, and adding this on
    /// top gave every piece two shadows that disagreed on shape, direction and
    /// density — see the note at that scene's lighting call.
    /// `name` ties the shadow to the piece casting it, so a piece lifted off the
    /// stage can take its shadow with it — the blob is a flat plane, not a real
    /// shadow, so hiding the gear alone leaves it printed on the floor.
    static func addContactShadow(to root: SCNNode, width: CGFloat, height: CGFloat,
                                 at p: SCNVector3, name: String? = nil) {
        let plane = SCNPlane(width: width, height: height)
        let m = SCNMaterial()
        m.diffuse.contents = radialShadowImage()
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.name = name
        node.eulerAngles.x = -.pi / 2                            // lay flat
        node.position = p
        node.renderingOrder = -10
        root.addChildNode(node)
    }

    // MARK: - Generated textures

    /// Soft vertical gradient used as the IBL environment (bright top → dark
    /// bottom) so metal picks up believable studio reflections without an HDR.
    static func environmentImage() -> UIImage {
        let size = CGSize(width: 256, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(white: 0.66, alpha: 1).cgColor,
                          UIColor(white: 0.30, alpha: 1).cgColor,
                          UIColor(white: 0.06, alpha: 1).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 0.55, 1]) else { return }
            ctx.cgContext.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0),
                                             end: CGPoint(x: 0, y: size.height), options: [])
        }
    }

    static func radialShadowImage() -> UIImage {
        let size = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let center = CGPoint(x: 128, y: 128)
            // Core alpha is 0.45, NOT the 0.88 this shipped with. At 0.88 the blob
            // read as a hole punched in the floor rather than a shadow — and it was
            // nearly three times the density of the real cast shadow
            // (`key.shadowColor`, alpha 0.30), which is the wrong way round for
            // something carrying no information about where the light is.
            let colors = [UIColor(white: 0, alpha: 0.45).cgColor,
                          UIColor(white: 0, alpha: 0.24).cgColor,
                          UIColor(white: 0, alpha: 0.0).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 0.55, 1]) else { return }
            ctx.cgContext.drawRadialGradient(grad, startCenter: center, startRadius: 0,
                                             endCenter: center, endRadius: 128, options: [])
        }
    }

    // MARK: - Knob angle (0–10 → −135°…+135°, negated for clockwise-from-front)

    static func knobAngle(forValue v: Double) -> Float {
        let frac = Float(max(0, min(10, v)) / 10)
        let deg = -135 + frac * 270
        return -deg * .pi / 180
    }

    // MARK: - Treadle angle (0–10 → heel-down…toe-down, ~20° of travel)

    /// A rocker pedal's treadle angle for a 0–10 `Position`, in radians about x.
    ///
    /// Inverted on purpose, and the sibling of `knobAngle` above: 0 is heel-down,
    /// which is the treadle at its STEEPEST, and 10 is toe-down, which is flat.
    /// That is what the value means to the player — a closed wah is the one
    /// standing up — and it is what the DSP already does with `Position`.
    ///
    /// The sign assumes a treadle hanging toward −z from a pivot at its heel,
    /// which is how the rocker archetypes build it (see `PedalArchetypes3D`); a
    /// positive x-rotation then lifts the toe. Change one and you must change
    /// the other. 20° is a real wah's usable sweep — enough to read across the
    /// stage, not so much that the pedal looks broken open.
    static func treadleAngle(forValue v: Double) -> Float {
        let frac = Float(max(0, min(10, v)) / 10)
        return (1 - frac) * 20 * .pi / 180
    }

    // MARK: - Geometry helpers

    /// The ribbed tread on a rocker's treadle, as thin raised bars running across
    /// `node` and spaced along its length.
    ///
    /// Real geometry rather than a texture: the stage is lit by one low key light,
    /// and a normal map on a plate this small at this distance disappears — a 1mm
    /// physical step still catches an edge highlight and still shows in silhouette.
    static func addGripRidges(count: Int, width: CGFloat, spacing: CGFloat, atY y: Float,
                              mat: SCNMaterial, to node: SCNNode) {
        guard count > 0 else { return }
        let start = -spacing * CGFloat(count - 1) / 2
        for i in 0..<count {
            let ridge = SCNBox(width: width, height: 0.04, length: 0.09, chamferRadius: 0.015)
            ridge.materials = [mat]
            let bar = SCNNode(geometry: ridge)
            bar.position = SCNVector3(0, y, Float(start + spacing * CGFloat(i)))
            node.addChildNode(bar)
        }
    }

    /// Add a chamfered box with one material at a position. Returns the node so
    /// callers can parent detail to it.
    @discardableResult
    static func addBox(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, chamfer: CGFloat,
                       mat: SCNMaterial, at p: SCNVector3, to root: SCNNode) -> SCNNode {
        let box = SCNBox(width: w, height: h, length: l, chamferRadius: chamfer)
        box.materials = [mat]
        let node = SCNNode(geometry: box)
        node.position = p
        root.addChildNode(node)
        return node
    }
}
