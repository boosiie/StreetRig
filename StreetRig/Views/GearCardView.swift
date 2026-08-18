//
//  GearCardView.swift
//  StreetRig
//
//  A single collection card: a vectorized picture of the actual gear + name.
//  Draggable — long-press and pull it onto the rig stage to swap that part.
//

import SwiftUI
import StreetRigEngine

struct GearCardView: View {
    @EnvironmentObject private var drag: RigDragController
    let item: GearItem

    /// Icon proportions per category (pedals tall & narrow, amps wide).
    private var iconSize: CGSize {
        switch item.category {
        case .amp:      return CGSize(width: 74, height: 50)
        case .cabinet:  return CGSize(width: 58, height: 54)
        case .comboAmp: return CGSize(width: 62, height: 52)
        case .guitar:   return CGSize(width: 42, height: 54)
        case .wah:      return CGSize(width: 64, height: 50)
        default:        return CGSize(width: 38, height: 54) // pedals
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            GearArtView(item: item)
                .frame(width: iconSize.width, height: iconSize.height)
                .frame(maxWidth: .infinity)
                .frame(height: 56)

            Text(item.name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(RigTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .frame(height: 28)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .rigCard(cornerRadius: 14)
        .opacity(drag.item?.id == item.id ? 0.35 : 1)   // dim the card that's lifted
        // `.simultaneousGesture` (not `.gesture`) so a quick swipe still scrolls
        // the rail; the ScrollView is disabled only once a drag actually starts
        // (see CollectionTabView.scrollDisabled).
        .simultaneousGesture(dragGesture)
    }

    /// Press-and-HOLD (~0.4s) to lift the card, then drag it onto the rig. The
    /// long hold is deliberate: a quick or slow swipe just scrolls the rail, and
    /// only an intentional press picks a card up. We use a real gesture (not
    /// `.draggable`) because the system drag won't reliably lift here — see
    /// RigDragController. Positions are in the shared "appRoot" space.
    private var dragGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(coordinateSpace: .named("appRoot")))
            .onChanged { value in
                if case .second(true, let move?) = value {
                    if drag.item == nil { drag.begin(item, at: move.location) }
                    else { drag.move(to: move.location) }
                }
            }
            .onEnded { _ in drag.end() }
    }
}

#Preview {
    HStack {
        GearCardView(item: GearItem(name: "Marshall JCM800", category: .amp))
        GearCardView(item: GearItem(name: "Ibonez Tube Screamer", category: .overdrive))
        GearCardView(item: GearItem(name: "DUNLAP CRY BABY", category: .wah))
    }
    .frame(width: 460)
    .padding()
    .background(RigTheme.background)
    .environmentObject(RigDragController())
    .preferredColorScheme(.dark)
}
