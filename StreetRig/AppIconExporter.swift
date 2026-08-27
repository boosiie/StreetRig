//
//  AppIconExporter.swift
//  StreetRig
//
//  Bakes `AppIconMark` to the three 1024×1024 PNGs that iOS 26 wants in
//  `Assets.xcassets/AppIcon.appiconset` — light, dark and tinted. The third
//  sibling of `ModelExporter` (3D) and `PanelArtExporter` (2D panels), and the
//  same deal: debug-only, driven by a launch environment variable, writes into
//  the app's Documents folder and prints the paths.
//
//  Run it with `STREETRIG_EXPORT_ICON=1` in the scheme's launch environment
//  (Debug), or from the command line against a simulator:
//
//      SIMCTL_CHILD_STREETRIG_EXPORT_ICON=1 \
//        xcrun simctl launch <UDID> streetrig.StreetRig
//
//  `=2` and `=3` emit 2048² and 3072² instead — same code, same three variants,
//  for marketing renders and any future slot (3072² verified). `=probe` additionally
//  writes the comparison sheets described below. Files land in `Documents/AppIcon/`
//  and are then copied into the asset catalog by hand:
//
//      xcrun simctl get_app_container <UDID> streetrig.StreetRig data
//      cp <that>/Documents/AppIcon/*.png StreetRig/Assets.xcassets/AppIcon.appiconset/
//
//  ── THE RENDER-ROUTE FINDING ────────────────────────────────────────────────
//
//  The mark's knobs are shaded by a Metal `.colorEffect` (Shaders/KnobMark.metal),
//  and the obvious worry is that an offscreen rasteriser quietly drops the shader
//  and hands back flat untextured circles — no error, just a worse icon. That is
//  not a thing to assume either way, so `=probe` renders the same view four ways
//  and writes all four for eyeballing:
//
//      probe-imagerenderer-shaded    ImageRenderer, Metal on
//      probe-imagerenderer-unshaded  ImageRenderer, the gradient fallback
//      probe-window-1024             a real 1024pt UIWindow, drawHierarchy()
//      probe-window-scaled           a screen-sized UIWindow at 2.98× scale
//
//  MEASURED, on iOS 26.5 / iPhone 16 Pro simulator: see the note on `route`.
//
//  `=probe` also writes three `probe-lift±0.0nn` bakes — the same icon at three
//  vertical offsets, for the optical-centring call. See `AppIconMark.extraLift`.
//

import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import StreetRigEngine

enum AppIconExporter {

    /// The icon's logical side. 1024 is the only size the catalog wants; `scale`
    /// is what makes bigger ones.
    static let side: CGFloat = 1024

    // MARK: - Route

    enum Route {
        /// `ImageRenderer` — SwiftUI's own offscreen rasteriser. No window, no run
        /// loop, no scene; works from `App.init`.
        case offscreen
        /// A real `UIWindow` on the app's scene, captured with
        /// `drawHierarchy(in:afterScreenUpdates:)`. Goes through the render server,
        /// so GPU-composited content is included — but it needs a live scene, a
        /// run-loop turn, and a window that actually fits somewhere.
        case live
    }

    /// FINDING, measured 2026-08-27 on the iOS 26.5 simulator (iPhone 16 Pro), by
    /// baking the probe and looking at the four PNGs:
    ///
    ///   **`ImageRenderer` DOES rasterise SwiftUI `.colorEffect` Metal shaders.**
    ///
    /// `probe-imagerenderer-shaded` came back with the full knurl, the anisotropic
    /// bowtie, the bevel rim, the pointer bloom and the crevice occlusion — the
    /// splash mark, at 1024. It is not a case of "looks plausible either way": the
    /// `-unshaded` probe beside it is unmistakably the gradient fallback, flat and
    /// ringed and a full hue yellower, which is what proves the two paths were
    /// really being compared and not two copies of one failure. So the
    /// `AmpLogoView.shaded: false` seam is NOT what the icon bakes through; it stays
    /// as the escape hatch it was built to be, and this exporter uses `shaded: true`
    /// like everything else.
    ///
    /// The `.live` route also works — a 1024pt window composites fine even though it
    /// is far bigger than the screen — but it came back with a black band a few
    /// pixels wide down the left and top edges, and it needs a scene, a nested
    /// run-loop spin and a window nobody can see. Kept only as the fallback if a
    /// future OS regresses the offscreen path.
    ///
    /// So: offscreen. Simplest, deterministic, no window plumbing, and one source of
    /// truth for the mark.
    static let route: Route = .offscreen

    // MARK: - Launch trigger

    /// Called from the scene's `.task` in `StreetRigApp`, under `#if DEBUG`.
    ///
    /// Runs inline, because by the time a `.task` on the scene's content fires
    /// there IS a connected `UIWindowScene` and the Metal shader library has
    /// resolved — which is the whole precondition this bake needs. An earlier cut
    /// called this from `App.init()` and bought the same guarantee with a 1.5s
    /// `asyncAfter`; that was a guess about how long a scene takes to come up, and
    /// it would have been wrong on a cold launch on a slow device. `PanelArtExporter`
    /// is triggered from the same place for the same reason — see its `.task`.
    @MainActor
    static func runFromLaunchEnvironment(_ mode: String) {
        let scale: CGFloat
        switch mode {
        case "2": scale = 2
        case "3": scale = 3
        default:  scale = 1
        }
        if mode == "probe" { _ = exportProbe() }
        _ = exportAll(scale: scale)
    }

    // MARK: - Export

    /// Bake all three appearance variants. Returns the files written.
    @MainActor
    @discardableResult
    static func exportAll(scale: CGFloat = 1) -> [URL] {
        let dir = outputDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let pixels = Int((side * scale).rounded())
        var written: [URL] = []

        for variant in AppIconMark.Variant.allCases {
            let url = dir.appendingPathComponent(filename(variant, pixels: pixels))
            guard let data = iconData(variant, scale: scale) else {
                print("app-icon export failed for \(variant.rawValue)")
                continue
            }
            do {
                try data.write(to: url, options: .atomic)
                written.append(url)
            } catch {
                print("app-icon export failed for \(variant.rawValue): \(error)")
            }
        }

        print("=== StreetRig app-icon export → \(dir.path) ===")
        written.forEach { print("wrote \($0.lastPathComponent)") }
        print("=== end app-icon export: \(written.count) file(s) at \(pixels)² ===")
        return written
    }

    /// One variant as PNG data: opaque, sRGB, no alpha channel.
    @MainActor
    static func iconData(_ variant: AppIconMark.Variant, scale: CGFloat = 1) -> Data? {
        let content = AppIconMark(side: side, variant: variant)
        let image: UIImage?
        switch route {
        case .offscreen: image = renderOffscreen(content, side: side, scale: scale)
        case .live:      image = renderLive(content, side: side, scale: scale)
        }
        guard let image else { return nil }
        return flatten(image,
                       pixels: Int((side * scale).rounded()),
                       monochrome: variant == .tinted)
    }

    /// `AppIcon-1024.png`, `AppIcon-1024-Dark.png`, `AppIcon-1024-Tinted.png` — and
    /// the same names carrying 2048/3072 at the larger scales, so a marketing render
    /// can never be mistaken for the catalog asset.
    static func filename(_ variant: AppIconMark.Variant, pixels: Int) -> String {
        switch variant {
        case .light:  return "AppIcon-\(pixels).png"
        case .dark:   return "AppIcon-\(pixels)-Dark.png"
        case .tinted: return "AppIcon-\(pixels)-Tinted.png"
        }
    }

    static var outputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppIcon", isDirectory: true)
    }

    // MARK: - Renderers

    /// SwiftUI's offscreen rasteriser. `isOpaque` matters twice: it saves the
    /// flatten pass a composite, and it keeps `.plusLighter` (the ember wash and
    /// the pointer halo both use it) blending against an opaque backdrop rather
    /// than against nothing.
    @MainActor
    private static func renderOffscreen<V: View>(_ content: V, side: CGFloat, scale: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content: content.frame(width: side, height: side))
        renderer.scale = scale
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: side, height: side)
        return renderer.uiImage
    }

    /// The render-server route: host the view in a real window on the app's scene
    /// and snapshot it. Unused today (see `route`), kept as the fallback if
    /// `ImageRenderer` ever stops carrying `.colorEffect`.
    ///
    /// `afterScreenUpdates: true` is the whole point — it forces a commit through
    /// the render server, which is what pulls GPU-composited content into the
    /// snapshot. It also means the window has to be attached to a scene and laid
    /// out before the call, hence the nested run-loop spin. That spin is why this
    /// is a debug-only exporter and not something the app does.
    @MainActor
    private static func renderLive<V: View>(_ content: V, side: CGFloat, scale: CGFloat) -> UIImage? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            print("app-icon live capture: no window scene")
            return nil
        }

        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let window = UIWindow(windowScene: scene)
        window.frame = bounds
        window.backgroundColor = .black
        window.overrideUserInterfaceStyle = .dark
        // Below the app's own window so nothing flashes over the UI mid-bake.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.isHidden = false

        let host = UIHostingController(rootView: AnyView(content))
        host.view.frame = bounds
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.setNeedsLayout()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }

        window.isHidden = true
        window.rootViewController = nil
        return image
    }

    // MARK: - Flatten

    /// Redraw into an sRGB, **alpha-less** bitmap and encode as PNG.
    ///
    /// Two requirements collapse into this one pass. iOS rejects an app icon with
    /// an alpha channel, and `UIImage.pngData()` gives no guarantee about what it
    /// emits — so the destination context is built with `.noneSkipLast`, which
    /// means "no alpha channel exists", not "alpha happens to be 255 everywhere".
    /// And the tinted variant has to become a luminance map, which is a pixel
    /// operation on exactly this buffer.
    ///
    /// The context is pre-filled black so any pixel the draw somehow misses is
    /// opaque black rather than uninitialised memory.
    private static func flatten(_ image: UIImage, pixels: Int, monochrome: Bool) -> Data? {
        guard let source = image.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let ctx = CGContext(data: nil,
                                  width: pixels,
                                  height: pixels,
                                  bitsPerComponent: 8,
                                  bytesPerRow: pixels * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(rect)
        ctx.interpolationQuality = .high
        ctx.draw(source, in: rect)

        if monochrome, let buffer = ctx.data {
            desaturate(buffer, count: pixels * pixels, bytesPerRow: pixels * 4)
        }

        guard let out = ctx.makeImage() else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Turn the buffer into the luminance map iOS will make of it anyway, so the
    /// result is something that was DESIGNED for tinting rather than something that
    /// merely survived it.
    ///
    /// Rec.709 weights on the sRGB-encoded values — not linearised first. That is
    /// deliberate: it is the same naive desaturation the system's tint mapping and
    /// every image editor's "desaturate" apply, so what is checked here is what
    /// ships. Linearising would make the amber pointer measurably brighter on paper
    /// and no brighter on screen.
    ///
    /// Then a levels curve, and it is doing real work. MEASURED off the first bake:
    /// the mark's luminance lives between 55 and 155 out of 255 and the ground sits
    /// at 3–9, so a straight desaturation gives a dim grey mark on black — legible,
    /// but nothing like the brightness a tinted icon needs, because the system maps
    /// this luminance onto a tint ramp and a mark that never gets above half never
    /// reaches the light end of it.
    ///
    /// Black point 0.024 sits above the whole ground, so the field goes to a true
    /// zero. That was aimed a little lower — the intent was to leave ~13/255 under
    /// the cluster so the vignette survived — and the bake says it does not: the
    /// ground reads 0 everywhere, including between the knobs. Left there anyway,
    /// because it turns out to be the better icon. In colour the ground separates
    /// from the metal by HUE, and hue is exactly what this variant loses; in
    /// luminance it was never more than a few units off black, so what it actually
    /// contributed once flattened was haze around the one thing that has to read.
    ///
    /// White point 0.647 is the brightest metal in the bake, so the pointers and the
    /// bevel glints reach the top of the ramp instead of stopping around 60%. Gamma
    /// 0.78 then lifts the midtones — the knob BODY, the largest area in the mark
    /// and the thing that decides whether it reads at 60px. Measured after: the body
    /// lands near 120/255 and the peak at 242, against 71 and 201 before.
    private static func desaturate(_ buffer: UnsafeMutableRawPointer, count: Int, bytesPerRow: Int) {
        let blackPoint: Float = 0.024
        let whitePoint: Float = 0.647
        let gamma: Float      = 0.78
        let span = whitePoint - blackPoint
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 0, to: count * 4, by: 4) {
            let r = Float(bytes[i])     / 255
            let g = Float(bytes[i + 1]) / 255
            let b = Float(bytes[i + 2]) / 255
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let levelled = min(1, max(0, (luma - blackPoint) / span))
            let byte = UInt8(pow(levelled, gamma) * 255)
            bytes[i] = byte; bytes[i + 1] = byte; bytes[i + 2] = byte
        }
    }

    // MARK: - Probe

    /// Render the light variant four ways and write all four, so the question
    /// "does this rasteriser carry the Metal shader?" is answered by looking at
    /// files instead of by guessing. See the header, and `route` for the answer.
    @MainActor
    @discardableResult
    static func exportProbe() -> [URL] {
        let dir = outputDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var written: [URL] = []
        func write(_ name: String, _ image: UIImage?, pixels: Int) {
            guard let image, let data = flatten(image, pixels: pixels, monochrome: false) else {
                print("probe \(name): NO IMAGE")
                return
            }
            let url = dir.appendingPathComponent("probe-\(name).png")
            try? data.write(to: url, options: .atomic)
            written.append(url)
        }

        let shaded   = AppIconMark(side: side, variant: .light, shaded: true)
        let unshaded = AppIconMark(side: side, variant: .light, shaded: false)

        write("imagerenderer-shaded",   renderOffscreen(shaded,   side: side, scale: 1), pixels: 1024)
        write("imagerenderer-unshaded", renderOffscreen(unshaded, side: side, scale: 1), pixels: 1024)
        write("window-1024",            renderLive(shaded, side: side, scale: 1),        pixels: 1024)
        // A window that actually FITS the screen, scaled up to 1024px instead. If
        // the full-size window comes back blank or clipped, this is why — a window
        // larger than its screen may never be composited.
        write("window-scaled",          renderLive(shaded, side: 344, scale: 1024.0 / 344.0), pixels: 1024)

        // Optical centring, decided by looking. `AmpLogoView` already lifts the
        // triangle 0.030 of its own size to sit its perceived centre on its frame's
        // centre — but that was judged on the SPLASH, where a wordmark hangs off the
        // bottom edge and adds mass below. The icon has no wordmark, so the right
        // extra lift here is its own question. Three candidates, same picture.
        for lift in [-0.020, 0.0, 0.012] as [CGFloat] {
            let tag = String(format: "%+.3f", Double(lift))
            write("lift\(tag)", renderOffscreen(AppIconMark(side: side, variant: .light, lift: lift),
                                                side: side, scale: 1), pixels: 1024)
        }

        print("=== StreetRig app-icon PROBE → \(dir.path) ===")
        written.forEach { print("wrote \($0.lastPathComponent)") }
        print("=== end probe: \(written.count) file(s) ===")
        return written
    }
}
