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
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(RigTheme.backgroundLift)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(RigTheme.trim.opacity(0.5), lineWidth: 1)
            )
            .overlay(
                Image(systemName: category.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(RigTheme.amber)
                    .padding(6)
            )
    }
}
