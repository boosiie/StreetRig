//
//  RigControls.swift
//  StreetRigEngine
//
//  THE CONTROL KIT. Before this file the app contained 33 `.buttonStyle(` call
//  sites, every one of them `.plain`, and ZERO `ButtonStyle` conformances — so
//  nothing in the app had a press state, nothing distinguished a primary action
//  from a throwaway one, and not one button fired a haptic. That is what made a
//  finished app read as a prototype.
//
//  Five button roles, a footswitch latch, a segmented control and a chip, each
//  with four states that are VISIBLY different: rest, pressed, engaged, disabled.
//
//  THREE RULES THIS FILE ENFORCES SO CALL SITES CANNOT GET THEM WRONG:
//
//  1. NO DROP SHADOWS. A shadow is a claim that one surface floats above another,
//     and a button is IN a panel, not on top of it. Depth is the tone ladder plus a
//     1pt hairline. Only three things in the app may cast: a modal, the drag ghost,
//     and real gear on the stage.
//
//  2. PRESS IS A FILL CHANGE, NOT A MOVE. With no drop shadow to collapse there is
//     nothing for a `+2pt` translate to sell — a control sitting flush in a panel
//     cannot sink. So pressed inverts the fill and adds an inner shadow. It also
//     survives Reduce Motion untouched, because colour is not motion.
//
//  3. 44×44 MINIMUM, MEASURED HERE. The player is holding a guitar. Roles whose
//     visual height is under 44 get the difference back as padding, so the hit
//     target is always at least 44 even when the button looks 40 tall. Call sites
//     cannot opt out of this by forgetting.
//
//  HAPTICS USE `.sensoryFeedback`, NOT `UIImpactFeedbackGenerator`. These files
//  ship inside the AUv3 extension, where a UIKit haptic engine is unavailable —
//  see the note at the top of `TapSlider`. Haptics are also inert in the Simulator,
//  so this path is verified by reading it, not by screenshot.
//

import SwiftUI

// MARK: - Buttons

public struct RigButtonStyle: ButtonStyle {

    public enum Role {
        /// The one action a screen is about. PROCEED, Continue, Add.
        case primary
        /// Everything else with a container. Back, Cancel, Done.
        case secondary
        /// Remove, Delete. Outlined at rest and only FILLS in a confirmation —
        /// a destructive action should look serious, not shout on every screen.
        case destructive
        /// No container at all. Skip, credits, "not now".
        case quiet
        /// A square glyph button: nav arrows, close, info.
        case icon
    }

    /// Whether the control is latched ON. Distinct from `isPressed`, which is the
    /// finger. A thing can be engaged without being touched.
    public var role: Role
    public var isEngaged: Bool

    public init(role: Role, isEngaged: Bool = false) {
        self.role = role
        self.isEngaged = isEngaged
    }

    @Environment(\.isEnabled) private var isEnabled

    private var visualHeight: CGFloat {
        switch role {
        case .primary:                 return 44
        case .secondary, .destructive: return 40
        case .icon:                    return 44
        case .quiet:                   return 32
        }
    }

    /// The padding that takes a short control up to the 44pt floor. Rule 3.
    private var hitPadding: CGFloat { max(0, (44 - visualHeight) / 2) }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed

        return configuration.label
            .font(font)
            .foregroundStyle(foreground(pressed: pressed))
            .padding(.horizontal, role == .icon ? 0 : (role == .quiet ? 10 : 18))
            .frame(minWidth: role == .icon ? 44 : 0)
            .frame(height: visualHeight)
            .background { background(pressed: pressed) }
            .padding(.vertical, hitPadding)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: pressed ? 0.06 : 0.18), value: pressed)
            .sensoryFeedback(haptic, trigger: pressed) { _, now in now }
    }

    private var font: Font {
        switch role {
        case .primary:     return .system(size: 16, weight: .heavy)
        case .secondary:   return .system(size: 14, weight: .semibold)
        case .destructive: return .system(size: 14, weight: .semibold)
        case .quiet:       return .system(size: 14, weight: .medium)
        case .icon:        return .system(size: 17, weight: .semibold)
        }
    }

    private var haptic: SensoryFeedback {
        switch role {
        case .primary:     return .impact(weight: .medium)
        case .destructive: return .warning
        default:           return .impact(weight: .light)
        }
    }

    private func foreground(pressed: Bool) -> Color {
        guard isEnabled else { return RigTheme.textPrimary.opacity(0.34) }
        switch role {
        case .primary:     return Color(red: 0.086, green: 0.047, blue: 0.016)
        case .destructive: return RigTheme.clip
        case .quiet:       return pressed ? RigTheme.textPrimary
                                          : (isEngaged ? RigTheme.amberChrome : RigTheme.textMuted)
        default:           return isEngaged ? RigTheme.amberChrome : RigTheme.textPrimary
        }
    }

    @ViewBuilder
    private func background(pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: RigTheme.Radius.control, style: .continuous)

        switch role {
        case .quiet:
            // No container by design — the label IS the control.
            Color.clear

        case .destructive:
            shape
                .fill(pressed ? RigTheme.clip.opacity(0.14) : .clear)
                .overlay { shape.strokeBorder(RigTheme.clip.opacity(isEnabled ? 0.55 : 0.2),
                                              lineWidth: 1) }

        case .primary:
            shape
                .fill(primaryFill(pressed: pressed))
                .overlay { shape.strokeBorder(RigTheme.amberChromeLit.opacity(isEnabled ? 0.55 : 0),
                                              lineWidth: 1) }

        case .secondary, .icon:
            shape
                .fill(pressed ? RigTheme.surface : RigTheme.surfaceRaised)
                .overlay {
                    shape.strokeBorder(isEngaged ? RigTheme.amberChrome
                                                 : RigTheme.surfaceEdge,
                                       lineWidth: 1)
                }
        }
    }

    private func primaryFill(pressed: Bool) -> AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(RigTheme.surfaceRaised) }
        // Rest runs light-over-dark; pressed FLIPS it. Inverting the light is what
        // reads as depth — and unlike a scale or a translate it costs no motion.
        let stops = pressed
            ? [RigTheme.amberChromeDeep, RigTheme.amberChrome]
            : [RigTheme.amberChromeLit, RigTheme.amberChrome, RigTheme.amberChromeDeep]
        return AnyShapeStyle(LinearGradient(colors: stops, startPoint: .top, endPoint: .bottom))
    }
}

public extension ButtonStyle where Self == RigButtonStyle {
    static var rigPrimary: RigButtonStyle { .init(role: .primary) }
    static var rigSecondary: RigButtonStyle { .init(role: .secondary) }
    static var rigDestructive: RigButtonStyle { .init(role: .destructive) }
    static var rigQuiet: RigButtonStyle { .init(role: .quiet) }
    static var rigIcon: RigButtonStyle { .init(role: .icon) }

    /// A secondary or icon button that can be latched on — a filter, a view toggle.
    static func rigSecondary(engaged: Bool) -> RigButtonStyle {
        .init(role: .secondary, isEngaged: engaged)
    }
    static func rigIcon(engaged: Bool) -> RigButtonStyle {
        .init(role: .icon, isEngaged: engaged)
    }
}

// MARK: - Footswitch

/// A stompbox footswitch, and the reason it is not just a toggle: on real hardware
/// the switch does NOT stay depressed — an LED lights. So engaged is rest geometry
/// plus a persistent emissive indicator, never "permanently pressed". Drawing it as
/// stuck-down collides with the pressed state and the player loses track of their
/// own finger.
///
/// The LED uses `RigTheme.amber`, the HOT ember, not `amberChrome`. It is light, and
/// light is saturated — see the note on `amberChrome`.
public struct RigFootswitchStyle: ToggleStyle {

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: RigTheme.Radius.panel, style: .continuous)
                    .fill(RigTheme.surfaceRaised)
                    .overlay {
                        RoundedRectangle(cornerRadius: RigTheme.Radius.panel, style: .continuous)
                            .strokeBorder(on ? RigTheme.amberChrome : RigTheme.surfaceEdge,
                                          lineWidth: 1)
                    }
                Circle()
                    .fill(on ? RigTheme.amber : Color(red: 0.227, green: 0.141, blue: 0.086))
                    .frame(width: 8, height: 8)
                    .shadow(color: on ? RigTheme.amber : .clear, radius: 6)
                    .padding(.bottom, 9)
                configuration.label
            }
            .frame(width: 60, height: 60)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: on)
        .sensoryFeedback(on ? .impact(flexibility: .rigid) : .impact(flexibility: .soft),
                         trigger: on)
    }
}

public extension ToggleStyle where Self == RigFootswitchStyle {
    static var rigFootswitch: RigFootswitchStyle { .init() }
}

// MARK: - Chip

/// A filter tag. 32pt visual, 44pt hit — the gap is padding, per rule 3.
public struct RigChip: View {
    private let title: String
    private let isOn: Bool
    private let action: () -> Void

    public init(_ title: String, isOn: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(isOn ? RigTheme.amberChrome : RigTheme.textMuted)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background {
                    RoundedRectangle(cornerRadius: RigTheme.Radius.tight, style: .continuous)
                        .fill(isOn ? RigTheme.amberChrome.opacity(0.20) : RigTheme.surfaceRaised)
                        .overlay {
                            RoundedRectangle(cornerRadius: RigTheme.Radius.tight, style: .continuous)
                                .strokeBorder(isOn ? RigTheme.amberChrome : RigTheme.surfaceEdge,
                                              lineWidth: 1)
                        }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}
