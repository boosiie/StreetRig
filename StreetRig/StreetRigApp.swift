//
//  StreetRigApp.swift
//  StreetRig
//
//  Created by Jake C on 23/07/2026.
//

import SwiftUI

@main
struct StreetRigApp: App {
    @StateObject private var store = RigStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
