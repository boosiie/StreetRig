//
//  GearCardView.swift
//  StreetRig
//
//  A single collection card: a vectorized picture of the actual gear + name.
//  Draggable — long-press and pull it onto the rig stage to swap that part.
//

import SwiftUI

struct GearCardView: View {
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(RigTheme.backgroundLift)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .draggable(item) {
            GearArtView(item: item)
                .frame(width: iconSize.width, height: iconSize.height)
                .padding(8)
        }
    }
}

#Preview {
    HStack {
        GearCardView(item: GearItem(name: "Marshall JCM800", category: .amp))
        GearCardView(item: GearItem(name: "Tube Screamer", category: .overdrive))
        GearCardView(item: GearItem(name: "Cry Baby", category: .wah))
    }
    .frame(width: 460)
    .padding()
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}
