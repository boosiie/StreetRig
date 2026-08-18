//
//  GearGlyphView.swift
//  StreetRigEngine
//
//  A tiny, self-contained gear icon for the SHARED control surface (the plugin
//  editor and the framework `ControlBoardView`). It draws an SF Symbol from the
//  gear category tinted with the rig palette — deliberately NOT the app's
//  `GearArtView`, which resolves bespoke per-model art from the app's asset
//  catalog via `GearIconLoader` (an app-only dependency `Bundle.main` would not
//  find inside the AUv3 extension sandbox). Keeping the shared UI on this glyph
//  means the plugin editor is self-contained and never reaches into the host app.
//

import SwiftUI

public struct GearGlyphView: View {
    let item: GearItem?

    public init(item: GearItem?) { self.item = item }

    public var body: some View {
        let category = item?.category ?? .overdrive
        // `Color.clear` (not a filled shape) so the tile still takes whatever frame
        // its caller hands it, while `.rigRaised` draws the well behind the glyph.
        // The brass edge stays: on this tile the border is the gear's trim, not the
        // generic card hairline.
        Color.clear
            .overlay(
                Image(systemName: category.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(RigTheme.amber)
                    .padding(6)
            )
            .rigRaised(cornerRadius: 8, stroke: RigTheme.trim.opacity(0.5))
    }
}
