//
//  MainView.swift
//  StreetRig
//
//  Placeholder for the main "My Rig" overview screen. The loading screen
//  fades into this. Real content (preset scenes, gear chain) comes later.
//

import SwiftUI

struct MainView: View {
    var body: some View {
        ZStack {
            RigTheme.background.ignoresSafeArea()

            VStack(spacing: 16) {
                AmpLogoView(size: 64)
                Text("StreetRig")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(RigTheme.textPrimary)
                Text("Main screen coming soon")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(RigTheme.textMuted)
            }
        }
    }
}

#Preview {
    MainView()
        .preferredColorScheme(.dark)
}
