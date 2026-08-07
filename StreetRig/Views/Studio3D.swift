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

    static func addLighting(to scene: SCNScene, keyIntensity: CGFloat = 850,
                            envIntensity: CGFloat = 1.25) {
        scene.lightingEnvironment.contents = environmentImage()   // IBL for PBR reflections
        scene.lightingEnvironment.intensity = envIntensity

        let key = SCNLight()
        key.type = .directional
        key.intensity = keyIntensity
        key.temperature = 6300                                  // neutral daylight, not warm
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.9, 0.5, 0)          // upper front-left
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 330
        fill.temperature = 6800
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(-0.25, -0.9, 0)       // soft right fill
        scene.rootNode.addChildNode(fillNode)

        // Cool rim light from behind-above for a clean studio edge highlight.
        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 460
        rim.temperature = 7400
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.eulerAngles = SCNVector3(0.6, 3.0, 0)
        scene.rootNode.addChildNode(rimNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 85
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
        cam.zNear = 0.05
        cam.zFar = 200
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
    static func addContactShadow(to root: SCNNode, width: CGFloat, height: CGFloat,
                                 at p: SCNVector3) {
        let plane = SCNPlane(width: width, height: height)
        let m = SCNMaterial()
        m.diffuse.contents = radialShadowImage()
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
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
            // Darker, denser core with a soft falloff so models read as grounded.
            let colors = [UIColor(white: 0, alpha: 0.88).cgColor,
                          UIColor(white: 0, alpha: 0.48).cgColor,
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

    // MARK: - Geometry helper

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
