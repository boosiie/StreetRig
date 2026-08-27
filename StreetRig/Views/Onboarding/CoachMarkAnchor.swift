//
//  CoachMarkAnchor.swift
//  StreetRig
//
//  HOW THE TOUR KNOWS WHERE ANYTHING IS. One `PreferenceKey` carrying a
//  dictionary of `Anchor<CGRect>`, one `.coachMarkTarget(_:)` modifier to tag a
//  view with it, and `CoachMarkTarget` — the closed list of things the tour is
//  allowed to point at.
//
//  WHY ANCHORS AND NOT FRAMES. The obvious version has each target publish
//  `proxy.frame(in: .named("appRoot"))` into an `ObservableObject`, and it works
//  right up until it doesn't: every target writes to the same object on every
//  layout pass, so the shell re-renders while it is laying out, and a rail that
//  scrolls under a spotlight redraws the whole tour. An `Anchor<CGRect>` is
//  opaque geometry that is resolved LATER, by whoever reads the preference,
//  against that reader's own `GeometryProxy` — so the value travels up the tree
//  with the layout instead of racing it, and one `.overlayPreferenceValue` on
//  MainView's root converts the lot into that root's coordinate space at once.
//
//  THE PAGER CAVEAT, WHICH IS THE WHOLE REASON THIS FILE HAS A `Resolved` TYPE.
//  The centre of the shell is a `TabView(.page)`, i.e. a UIPageViewController
//  bridge — the same bridge that made `RigDragController.appRootOrigin` measure
//  itself on the app root rather than trust a named coordinate space from
//  inside. Two things go wrong for anchors in there and both are handled in
//  `CoachMarkResolution`:
//
//    1. A page that is NOT the current one is still alive and still laid out,
//       one screen width to the left or right. Its anchors resolve perfectly —
//       to a rectangle nobody can see. A spotlight there is a hole cut in the
//       scrim over nothing.
//    2. An anchor may not arrive at all, or may arrive with a degenerate size,
//       while the pager is mid-transition.
//
//  So an in-page target is never trusted on its face: it is validated against
//  the container, and a target that fails validation falls back to the page
//  region — `.pageArea`, which is tagged on the TabView ITSELF, outside the
//  bridge, where measurement has never been in question. A broad spotlight with
//  the right caption teaches something. A precise one in the wrong place
//  teaches the player that the app is lying to them.
//

import SwiftUI

// MARK: - The closed list of things the tour can point at

/// Every element the coach-mark tour is allowed to spotlight.
///
/// A closed enum rather than free-form strings so a renamed target is a compile
/// error rather than a step that silently spotlights nothing. `outsidePager`
/// records which side of the `TabView` bridge each one lives on — see the file
/// header; it is what decides whether a resolved rect gets believed.
enum CoachMarkTarget: String, CaseIterable, Hashable {

    // MARK: Outside the pager — measurement here has never been in doubt

    /// The whole MY GEAR rail down the left.
    case gearRail
    /// The rail's first card — the one that demonstrates the lift.
    case railCard
    /// The red trash circle that fades in over the top-left of the centre area.
    case trash
    /// The top nav bar as a whole: arrows, title, dots. One target rather than
    /// three, because they are one control — the arrows, the dots and the header
    /// swipe are three ways to do the same thing, and three separate spotlights
    /// in a row would teach them as three separate features.
    case header
    /// The quiet info button at the top right.
    case credits
    /// The bottom control panel, whole.
    case controlPanel
    /// The PROCEED / STOP button.
    case transportZone
    /// The pager's own rectangle, tagged on the `TabView` — the fallback for
    /// anything inside it, and the spotlight for "this is the page area".
    case pageArea

    // MARK: Inside the pager — validated before they are believed

    /// The rig stage's content (`RigStageView`).
    case rigStage
    /// The profile page's identity column — avatar, name, privacy note.
    case profileIdentity

    /// True for targets that live OUTSIDE the `TabView` bridge. Their resolved
    /// rect is taken at face value; everything else is validated first.
    var outsidePager: Bool {
        switch self {
        case .rigStage, .profileIdentity: return false
        default: return true
        }
    }

    /// What VoiceOver calls this thing when the tour moves the spotlight onto it.
    var accessibleName: String {
        switch self {
        case .gearRail:        return "the MY GEAR rail"
        case .railCard:        return "a gear card in the rail"
        case .trash:           return "the trash target"
        case .header:          return "the top navigation bar"
        case .credits:         return "the credits button"
        case .controlPanel:    return "the control panel"
        case .transportZone:   return "the PROCEED button"
        case .pageArea:        return "the current page"
        case .rigStage:        return "the rig stage"
        case .profileIdentity: return "your profile"
        }
    }
}

// MARK: - The preference

/// Collects every tagged target's geometry on its way up the view tree.
///
/// `reduce` merges rather than overwrites, and lets the LAST writer win for a
/// duplicate key. Duplicates are expected and benign: the rail's first card is
/// tagged inside a `ForEach`, and the pager keeps neighbouring pages alive, so
/// two views can legitimately claim the same target for a frame or two during a
/// transition. Last-wins keeps the most recently laid-out one.
struct CoachMarkAnchorKey: PreferenceKey {
    static var defaultValue: [CoachMarkTarget: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [CoachMarkTarget: Anchor<CGRect>],
                       nextValue: () -> [CoachMarkTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

extension View {
    /// Tag this view as something the coach-mark tour can point at.
    ///
    /// `transformAnchorPreference`, NOT `anchorPreference`, and the difference is
    /// the whole reason nesting works. `anchorPreference` SETS this node's value
    /// for the key, which throws away everything the subtree below it wrote —
    /// and every one of these tags is nested inside another: the PROCEED button
    /// is inside the control panel, the credits button is inside the header, the
    /// rail's first card is inside the rail. The first cut of this used
    /// `anchorPreference` and the probe came back with exactly four targets out
    /// of ten: the four outermost ones, each having silently eaten its own
    /// children. `transformAnchorPreference` receives what the subtree produced
    /// and adds to it.
    ///
    /// Free at rest: a preference write per layout pass, and nothing at all when
    /// no one is reading it — which is why these can live permanently on the
    /// shell rather than being switched on when a tour starts.
    func coachMarkTarget(_ target: CoachMarkTarget) -> some View {
        transformAnchorPreference(key: CoachMarkAnchorKey.self, value: .bounds) { targets, anchor in
            targets[target] = anchor
        }
    }

    /// Tag one member of a `ForEach` — the rail's first card, which is the only
    /// one of forty-seven the tour has anything to say about. The condition is
    /// inside the transform rather than around the modifier so both branches are
    /// the same view type, which is what stops a re-ordered rail from reading as
    /// forty-seven brand-new views.
    func coachMarkTargetIf(_ condition: Bool, _ target: CoachMarkTarget) -> some View {
        transformAnchorPreference(key: CoachMarkAnchorKey.self, value: .bounds) { targets, anchor in
            guard condition else { return }
            targets[target] = anchor
        }
    }
}

// MARK: - Resolution

/// One target's geometry, already converted into the reader's coordinate space,
/// plus the honest record of whether it is the target that was ASKED for.
struct ResolvedCoachMark: Equatable {
    /// The rect to cut out of the scrim.
    let rect: CGRect
    /// What the rect actually belongs to. Differs from the requested target when
    /// an in-page anchor failed validation and the page region stood in.
    let target: CoachMarkTarget
    /// True when this is a fallback. The caption layer uses it to widen the
    /// spotlight's corner radius (a page-sized hole with a 10pt radius reads as
    /// a mistake) — and it is the flag to check when someone asks whether
    /// in-page anchoring actually worked.
    let isFallback: Bool
}

enum CoachMarkResolution {

    /// A rect has to be at least this big on both axes to be worth cutting a
    /// hole for. Below it the anchor is mid-layout or collapsed, not real.
    private static let minimumUsefulSide: CGFloat = 12

    /// Resolve `target` against `proxy`, falling back to the page region when an
    /// in-page anchor cannot be trusted. See the file header for the two ways
    /// pager geometry lies.
    ///
    /// - Parameter container: the reader's own bounds, i.e. the shell. A rect is
    ///   believed only if it overlaps this by a real amount.
    static func resolve(_ target: CoachMarkTarget,
                        anchors: [CoachMarkTarget: Anchor<CGRect>],
                        proxy: GeometryProxy) -> ResolvedCoachMark? {
        let container = CGRect(origin: .zero, size: proxy.size)

        if let anchor = anchors[target] {
            let rect = proxy[anchor]
            if isBelievable(rect, in: container, trustUnconditionally: target.outsidePager) {
                return ResolvedCoachMark(rect: rect, target: target, isFallback: false)
            }
        }

        // The fallback, and the ONLY fallback: the pager's own rectangle. It is
        // tagged outside the bridge, so if this one is missing the shell is not
        // on screen yet and there is nothing to point at anyway.
        guard let pageAnchor = anchors[.pageArea] else { return nil }
        let pageRect = proxy[pageAnchor]
        guard isBelievable(pageRect, in: container, trustUnconditionally: true) else { return nil }
        return ResolvedCoachMark(rect: pageRect, target: .pageArea,
                                 isFallback: target != .pageArea)
    }

    /// Is this rect worth cutting a hole for?
    ///
    /// Size first — a zero-height anchor is a view mid-layout. Then position:
    /// an off-screen rect is the neighbouring pager page, alive and correctly
    /// measured one screen width away. `trustUnconditionally` skips the position
    /// test for targets outside the bridge, which are allowed to hang slightly
    /// past an edge (the rail bleeds under the safe area, the trash sits over
    /// the page's corner).
    private static func isBelievable(_ rect: CGRect,
                                     in container: CGRect,
                                     trustUnconditionally: Bool) -> Bool {
        guard rect.width >= minimumUsefulSide, rect.height >= minimumUsefulSide,
              rect.width.isFinite, rect.height.isFinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite else { return false }
        if trustUnconditionally { return true }
        // Most of it has to be on screen. A page mid-swipe is half out; a
        // neighbouring page is entirely out. Two-thirds visible is the line.
        let overlap = rect.intersection(container)
        guard !overlap.isNull else { return false }
        let visibleArea = overlap.width * overlap.height
        let fullArea = rect.width * rect.height
        return fullArea > 0 && visibleArea / fullArea >= 0.66
    }
}

// MARK: - The probe

/// DEVELOPER TOOL, not a feature. Launch with `-CoachMarkProbe` and every tagged
/// target is outlined and named where it resolves.
///
/// It exists because the pager question in the file header cannot be answered by
/// reading code — it has to be seen. One screenshot with this on says which
/// anchors arrive, where they land, and which ones fall out of the pager
/// half a screen to the left. Left in the tree, behind a launch argument and a
/// `#if DEBUG`, because the same question comes back every time a page is added.
#if DEBUG
struct CoachMarkProbeOverlay: View {
    let anchors: [CoachMarkTarget: Anchor<CGRect>]
    let proxy: GeometryProxy

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-CoachMarkProbe")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The reader's own frame and insets, which is the other half of the
            // question: everything below is in THIS space, and the scrim has to
            // know how far it sits inside the screen to punch its hole in the
            // right place.
            Text("reader \(Int(proxy.size.width))x\(Int(proxy.size.height))  "
                 + "safe t\(Int(proxy.safeAreaInsets.top)) l\(Int(proxy.safeAreaInsets.leading)) "
                 + "b\(Int(proxy.safeAreaInsets.bottom)) t\(Int(proxy.safeAreaInsets.trailing))")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black)
                .padding(2)
                .background(.yellow)
                .offset(x: 200, y: 120)

            ForEach(CoachMarkTarget.allCases, id: \.self) { target in
                if let anchor = anchors[target] {
                    let rect = proxy[anchor]
                    Rectangle()
                        .strokeBorder(target.outsidePager ? RigThemeProbe.outside : RigThemeProbe.inside,
                                      lineWidth: 1.5)
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                        .overlay(alignment: .topLeading) {
                            Text("\(target.rawValue) \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(1)
                                .background(target.outsidePager ? RigThemeProbe.outside : RigThemeProbe.inside)
                                .fixedSize()
                        }
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private enum RigThemeProbe {
        static let outside = Color.green
        static let inside = Color.cyan
    }
}
#endif
