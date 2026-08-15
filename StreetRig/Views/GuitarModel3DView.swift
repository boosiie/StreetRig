//
//  GuitarModel3DView.swift
//  StreetRig
//
//  The rig stage's guitar in 3D: a single-cutaway, Les Paul-style solidbody on a
//  simple A-frame stand, backed by SceneKit. The body is an extruded silhouette
//  (SCNShape from a bezier outline) with a cherry finish; it carries a set neck,
//  an "open-book" headstock with 3+3 tuners, two humbuckers, a bridge +
//  tailpiece, and four gold control knobs. A PROCEDURAL stand-in — generic, no
//  brand marks — with the same swap seam idea as the amp (drop in a real .usdz
//  later). Tap to open the guitar's detail view. Gated by `FeatureFlags.amp3D`.
//

import SwiftUI
import StreetRigEngine
import SceneKit
import UIKit

// MARK: - SwiftUI wrapper

struct GuitarModel3DView: UIViewRepresentable {
    var item: GearItem?
    var onTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = GuitarScene.make()
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true          // drag to inspect

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?
        init(onTap: (() -> Void)?) { self.onTap = onTap }
        @objc func handleTap() { onTap?() }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

// MARK: - Scene assembly

enum GuitarScene {
    static func make() -> SCNScene {
        let scene = SCNScene()

        let guitar = SCNNode()
        ProceduralGuitar.buildGuitar(into: guitar)
        guitar.eulerAngles.x = -0.10             // lean back onto the stand
        scene.rootNode.addChildNode(guitar)

        let stand = SCNNode()
        ProceduralGuitar.buildStand(into: stand)
        scene.rootNode.addChildNode(stand)

        Studio3D.addLighting(to: scene)
        Studio3D.addContactShadow(to: scene.rootNode, width: 2.6, height: 1.6,
                                  at: SCNVector3(0, -1.62, 0.1))
        // Portrait framing of a tall instrument.
        Studio3D.addCamera(to: scene, position: SCNVector3(0, 0.55, 8.6), tilt: 0, fov: 30)
        return scene
    }
}

// MARK: - Procedural Les Paul-style guitar (generic, no brand marks)

enum ProceduralGuitar {

    /// Single-cutaway solidbody outline (neck points +Y, treble cutaway on −X).
    private static func bodyPath() -> UIBezierPath {
        let p = UIBezierPath()
        p.flatness = 0.02   // fine tessellation → smooth bouts (default 0.6 is coarse at this scale)
        p.move(to: CGPoint(x: 0.00, y: -1.28))                                   // bottom center
        p.addCurve(to: CGPoint(x: 0.92, y: -0.42),                               // round lower-bass bout
                   controlPoint1: CGPoint(x: 0.62, y: -1.34), controlPoint2: CGPoint(x: 0.94, y: -0.92))
        p.addCurve(to: CGPoint(x: 0.66, y: 0.20),                                // bass waist
                   controlPoint1: CGPoint(x: 0.90, y: -0.02), controlPoint2: CGPoint(x: 0.72, y: 0.06))
        p.addCurve(to: CGPoint(x: 0.80, y: 0.80),                                // bass shoulder
                   controlPoint1: CGPoint(x: 0.60, y: 0.44), controlPoint2: CGPoint(x: 0.82, y: 0.56))
        p.addCurve(to: CGPoint(x: 0.22, y: 1.02),                                // to neck heel (bass)
                   controlPoint1: CGPoint(x: 0.78, y: 1.00), controlPoint2: CGPoint(x: 0.52, y: 1.04))
        p.addLine(to: CGPoint(x: -0.04, y: 1.02))                                // heel top
        p.addCurve(to: CGPoint(x: -0.82, y: 0.92),                               // treble horn tip
                   controlPoint1: CGPoint(x: -0.32, y: 1.01), controlPoint2: CGPoint(x: -0.82, y: 1.08))
        p.addCurve(to: CGPoint(x: -0.48, y: 0.44),                               // cutaway valley
                   controlPoint1: CGPoint(x: -0.82, y: 0.68), controlPoint2: CGPoint(x: -0.56, y: 0.52))
        p.addCurve(to: CGPoint(x: -0.66, y: 0.16),                               // treble waist
                   controlPoint1: CGPoint(x: -0.40, y: 0.34), controlPoint2: CGPoint(x: -0.66, y: 0.36))
        p.addCurve(to: CGPoint(x: -0.92, y: -0.42),                              // lower-treble bout
                   controlPoint1: CGPoint(x: -0.66, y: -0.04), controlPoint2: CGPoint(x: -0.94, y: -0.14))
        p.addCurve(to: CGPoint(x: 0.00, y: -1.28),                               // round bottom back to center
                   controlPoint1: CGPoint(x: -0.94, y: -0.92), controlPoint2: CGPoint(x: -0.62, y: -1.34))
        p.close()
        return p
    }

    static func buildGuitar(into root: SCNNode) {
        let cherry = UIColor(red: 0.46, green: 0.07, blue: 0.09, alpha: 1)
        let mahog  = UIColor(red: 0.24, green: 0.11, blue: 0.06, alpha: 1)
        let ebony  = UIColor(red: 0.06, green: 0.05, blue: 0.06, alpha: 1)
        let cream  = UIColor(red: 0.92, green: 0.88, blue: 0.74, alpha: 1)
        let gold   = UIColor(red: 0.83, green: 0.66, blue: 0.29, alpha: 1)
        let chrome = UIColor(white: 0.78, alpha: 1)

        // ---- Body (extruded silhouette; gloss via low roughness) ----
        let shape = SCNShape(path: bodyPath(), extrusionDepth: 0.36)
        shape.chamferRadius = 0.06
        shape.materials = [Studio3D.pbr(cherry, metalness: 0.1, roughness: 0.26)]
        let body = SCNNode(geometry: shape)
        body.position = SCNVector3(0, 0, -0.18)          // center the depth on z = 0
        root.addChildNode(body)
        let frontZ: Float = 0.20                          // hardware sits just proud of the top

        // ---- Neck + fretboard ----
        Studio3D.addBox(0.30, 1.55, 0.16, chamfer: 0.05, mat: Studio3D.pbr(mahog, metalness: 0, roughness: 0.5),
                        at: SCNVector3(0.10, 1.78, 0.12), to: root)
        let fbNode = Studio3D.addBox(0.28, 1.55, 0.05, chamfer: 0.01,
                                     mat: Studio3D.pbr(ebony, metalness: 0, roughness: 0.4),
                                     at: SCNVector3(0.10, 1.78, 0.22), to: root)
        // Frets
        for i in 0..<9 {
            let fret = SCNBox(width: 0.28, height: 0.014, length: 0.012, chamferRadius: 0)
            fret.materials = [Studio3D.pbr(chrome, metalness: 0.9, roughness: 0.3)]
            let fn = SCNNode(geometry: fret)
            fn.position = SCNVector3(0, -0.66 + Float(i) * 0.16, 0.028)
            fbNode.addChildNode(fn)
        }
        // Nut
        Studio3D.addBox(0.30, 0.05, 0.07, chamfer: 0.01, mat: Studio3D.pbr(cream, metalness: 0, roughness: 0.5),
                        at: SCNVector3(0.10, 2.56, 0.2), to: root)

        // ---- Headstock (open-book), tilted back ----
        let head = Studio3D.addBox(0.40, 0.52, 0.08, chamfer: 0.03,
                                   mat: Studio3D.pbr(ebony, metalness: 0, roughness: 0.35),
                                   at: SCNVector3(0.10, 2.86, 0.16), to: root)
        head.eulerAngles.x = 0.26
        for side in [-1, 1] as [Float] {
            for j in 0..<3 {
                let peg = SCNCylinder(radius: 0.028, height: 0.14)
                peg.materials = [Studio3D.pbr(gold, metalness: 0.9, roughness: 0.3)]
                let pn = SCNNode(geometry: peg)
                pn.eulerAngles.z = .pi / 2                 // lie sideways off the headstock edge
                pn.position = SCNVector3(side * 0.26, -0.14 + Float(j) * 0.17, 0.02)
                head.addChildNode(pn)
            }
        }

        // ---- Pickups (two humbuckers) ----
        for y in [0.56 as Float, 0.16] {
            let pu = SCNBox(width: 0.56, height: 0.22, length: 0.08, chamferRadius: 0.02)
            pu.materials = [Studio3D.pbr(UIColor(white: 0.07, alpha: 1), metalness: 0.25, roughness: 0.5)]
            let pn = SCNNode(geometry: pu)
            pn.position = SCNVector3(-0.04, y, frontZ)
            root.addChildNode(pn)
        }

        // ---- Bridge + tailpiece (chrome bars) ----
        for y in [-0.06 as Float, -0.30] {
            let bar = SCNBox(width: 0.52, height: 0.08, length: 0.1, chamferRadius: 0.02)
            bar.materials = [Studio3D.pbr(chrome, metalness: 0.9, roughness: 0.25)]
            let bn = SCNNode(geometry: bar)
            bn.position = SCNVector3(-0.04, y, frontZ)
            root.addChildNode(bn)
        }

        // ---- Pickguard (cream, treble side) ----
        let pg = SCNBox(width: 0.34, height: 0.6, length: 0.03, chamferRadius: 0.04)
        pg.materials = [Studio3D.pbr(cream, metalness: 0, roughness: 0.55)]
        let pgNode = SCNNode(geometry: pg)
        pgNode.position = SCNVector3(-0.46, 0.30, frontZ - 0.01)
        pgNode.eulerAngles.z = 0.18
        root.addChildNode(pgNode)

        // ---- Four gold control knobs (lower bout) ----
        for pos in [SIMD2<Float>(-0.30, -0.52), SIMD2<Float>(0.06, -0.46),
                    SIMD2<Float>(-0.26, -0.86), SIMD2<Float>(0.10, -0.80)] {
            let knob = SCNCylinder(radius: 0.085, height: 0.1)
            knob.materials = [Studio3D.pbr(gold, metalness: 0.85, roughness: 0.3)]
            let kn = SCNNode(geometry: knob)
            kn.eulerAngles.x = .pi / 2                     // face forward
            kn.position = SCNVector3(pos.x, pos.y, frontZ)
            root.addChildNode(kn)
        }
    }

    /// A minimal, generic A-frame stand the body rests in.
    static func buildStand(into root: SCNNode) {
        let mat = Studio3D.pbr(UIColor(white: 0.28, alpha: 1), metalness: 0.6, roughness: 0.45)

        func bar(length: CGFloat, at p: SCNVector3, rotZ: Float = 0, rotX: Float = 0) {
            let cyl = SCNCylinder(radius: 0.036, height: length)
            cyl.materials = [mat]
            let n = SCNNode(geometry: cyl)
            n.eulerAngles = SCNVector3(rotX, 0, rotZ)
            n.position = p
            root.addChildNode(n)
        }

        // Two splayed legs forming an A, set well behind the guitar.
        bar(length: 2.7, at: SCNVector3(-0.55, -0.78, -0.5), rotZ: 0.34, rotX: -0.22)
        bar(length: 2.7, at: SCNVector3(0.55, -0.78, -0.5), rotZ: -0.34, rotX: -0.22)
        // Low cross brace.
        bar(length: 1.2, at: SCNVector3(0, -1.5, -0.44), rotZ: .pi / 2)
        // Short cradle arms at the very bottom that hold the lower bout.
        bar(length: 0.46, at: SCNVector3(-0.26, -1.24, 0.12), rotZ: 0.62)
        bar(length: 0.46, at: SCNVector3(0.26, -1.24, 0.12), rotZ: -0.62)
    }
}

#Preview {
    GuitarModel3DView(item: GearItem(name: "Les Paul Standard", category: .guitar))
        .frame(width: 150, height: 260)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}
