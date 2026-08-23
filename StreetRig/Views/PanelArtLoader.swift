//
//  PanelArtLoader.swift
//  StreetRig
//
//  THE FACEPLATE SEAM — the knob panel's surface as an editable PNG, one per
//  component. The zoomed-in panel in ComponentDetailView used to be a flat fill
//  of the piece's signature colour under a standing gradient, drawn in code; now
//  it is a picture, and the picture is a file you can open, repaint and drop
//  back. Brushed gold for the Marswell, cream for the Fandor, a screened logo,
//  screws, tolex, wear — none of it costs a line of Swift.
//
//  WHAT THE PNG IS, EXACTLY: the surface UNDER the knobs and nothing else. The
//  knobs, their captions and the channel dividers stay live views drawn on top —
//  they have to, because they turn. So a plate is a flat rectangle of art at the
//  panel's own proportions (see `KnobPanelLayout.height`), and the app rounds its
//  corners and strokes its edge exactly as it always did.
//
//  THREE PLACES A PLATE CAN LIVE, first hit wins:
//    1. `Documents/PanelArt/<slug>-panel.png` — the live override. It shows up in
//       the Files app under "On My iPhone → StreetRig", so a plate can be edited
//       on the device and seen on the next look at the panel; the cache is
//       dropped when the app comes back to the foreground, which is exactly when
//       you return from editing one.
//    2. `<slug>-panel.png` bundled — the shipped plate, dropped into
//       `StreetRig/PanelArt/` in the repo. Every catalog piece with knobs has one.
//    3. `category-<category>-panel.png` bundled — one plate for a whole category.
//    4. …nothing, and the panel draws `ProceduralPlate` exactly as before.
//
//  The name rule is `GearIconLoader.slug` — the SAME slug the icons and the
//  `.usdz` models resolve by, with a `-panel` suffix so a plate can never collide
//  with the piece's icon. One name convention, three seams.
//

import Combine          // @Published needs it explicitly in Swift 5 mode
import SwiftUI
import StreetRigEngine
import UIKit

// MARK: - Facts a plate and the panel behind it have to agree on

enum PanelArt {

    /// THE PANEL'S STANDING SHADING — a touch of light off the top, a touch of
    /// shadow at the bottom. Shared between `ProceduralPlate` (what the panel
    /// draws when no plate exists) and the baked PNGs (which are rendered FROM
    /// that same view), so the shipped plates and the fallback cannot drift.
    static let gradientStops: [Gradient.Stop] = [
        .init(color: .white.opacity(0.12), location: 0),
        .init(color: .clear, location: 0.5),
        .init(color: .black.opacity(0.16), location: 1),
    ]

    /// The width a baked plate is authored at. The panel is as wide as the sheet,
    /// so its real width is the device's — this is simply the landscape phone's,
    /// which fixes the ASPECT the plates are drawn to. Height comes per piece from
    /// `KnobPanelLayout.height`, so a six-knob amp bakes a tall plate and a
    /// three-knob pedal bakes a strip, which is what each one is on screen.
    static let referenceWidth: CGFloat = 800

    /// Pixels per point in a baked plate — a canvas worth painting on.
    static let exportScale: CGFloat = 3

    /// The plate file name for a piece: `ibonez-tube-screamer-panel`. Empty when
    /// the piece has no usable name (the library's placeholder headers).
    static func plateName(for item: GearItem) -> String {
        let slug = GearIconLoader.slug(item.name)
        return slug.isEmpty ? "" : "\(slug)-panel"
    }

    /// The shared plate name for a whole category: `category-overdrive-panel`.
    static func categoryPlateName(for item: GearItem) -> String {
        "category-\(item.category.rawValue)-panel"
    }

    /// Formats a plate may be authored in. PNG first — it is what the exporter
    /// bakes and the only one that can carry transparency over the piece's colour.
    static let extensions = ["png", "jpg", "jpeg"]
}

// MARK: - The plate the app draws when no PNG exists

/// The ORIGINAL knob panel surface: the piece's signature colour under the
/// standing shading. Two jobs — it is the fallback for any piece with no plate
/// (a custom-named amp somebody adds), and it is what `PanelArtExporter` renders
/// to bake the shipped PNGs. Baking the fallback is the point: a freshly exported
/// plate is pixel-for-pixel the panel you already had, so it is a starting canvas
/// rather than a blank one.
struct ProceduralPlate: View {
    let item: GearItem?

    var body: some View {
        Rectangle()
            .fill(GearArtView.panelColor(for: item))
            .overlay(
                LinearGradient(stops: PanelArt.gradientStops,
                               startPoint: .top, endPoint: .bottom)
            )
    }
}

// MARK: - "The plates changed"

/// A one-integer observable whose only job is to make a panel that is ALREADY on
/// screen redraw itself.
///
/// Dropping the loader's cache tells SwiftUI nothing — the view has no reason to
/// re-evaluate its body, so an edit made in the Files app would sit invisible
/// behind a stale image until the panel was closed and reopened. A panel that
/// observes this redraws the moment the plates are invalidated, which is what
/// makes "edit it, switch back, look at it" true.
final class PanelArtRevision: ObservableObject {
    static let shared = PanelArtRevision()
    @Published private(set) var generation = 0
    fileprivate func bump() { generation &+= 1 }
    private init() {}
}

// MARK: - Resolving a piece to its plate

enum PanelArtLoader {

    /// `Documents/PanelArt` — the folder the Files app shows and the exporter
    /// writes into. Created on demand; nothing here fails if it is missing.
    static var overrideDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PanelArt", isDirectory: true)
    }

    /// The faceplate for a piece, or `nil` to draw `ProceduralPlate`.
    static func uiImage(for item: GearItem?) -> UIImage? {
        guard let item else { return nil }
        let name = PanelArt.plateName(for: item)
        guard !name.isEmpty else { return nil }

        _ = foregroundWatch      // arm the re-read on first use (see below)

        let key = "\(name)|\(item.category.rawValue)"
        if let cached = cache[key] { return cached }
        let found = resolve(name: name, category: PanelArt.categoryPlateName(for: item))
        cache[key] = found       // negative results too: a miss must not re-hit
        return found             // the filesystem on every knob turn
    }

    static func image(for item: GearItem?) -> Image? {
        uiImage(for: item).map { Image(uiImage: $0) }
    }

    /// Forget every resolved plate, so the next panel re-reads from disk, and tell
    /// any panel on screen to redraw. Called on foreground — you edited a plate in
    /// the Files app and came back.
    static func invalidate() {
        cache.removeAll()
        PanelArtRevision.shared.bump()
    }

    // MARK: - Private

    /// Documents override → bundled plate → bundled category plate → nil.
    private static func resolve(name: String, category: String) -> UIImage? {
        let dir = overrideDirectory
        for ext in PanelArt.extensions {
            let url = dir.appendingPathComponent("\(name).\(ext)")
            if let ui = UIImage(contentsOfFile: url.path) { return ui }
        }
        for stem in [name, category] {
            for ext in PanelArt.extensions {
                if let url = Bundle.main.url(forResource: stem, withExtension: ext),
                   let ui = UIImage(contentsOfFile: url.path) { return ui }
            }
        }
        return nil
    }

    /// A plate is loaded from a FILE, so unlike `UIImage(named:)` nothing caches
    /// it for us — and the panel's body is re-evaluated on every frame of a knob
    /// drag. Without this a turn of the Gain knob would re-decode a 2400 px PNG
    /// sixty times a second.
    private static var cache: [String: UIImage?] = [:]

    /// Registered once, lazily, the first time anything asks for a plate.
    private static let foregroundWatch: Any = NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil, queue: .main
    ) { _ in invalidate() }
}
