// ContentView.swift - the four tabs, the scene-phase hook and the "Glass paired" alert.

import Foundation
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var link = GlassLink.shared

    var body: some View {
        TabView {
            GlassTab()
                .tabItem {
                    Label("Glass", systemImage: "eyeglasses")
                }
            NavigateTab()
                .tabItem {
                    Label("Navigate", systemImage: "map")
                }
            MediaTab()
                .tabItem {
                    Label("Media", systemImage: "photo.on.rectangle")
                }
            ToolsTab()
                .tabItem {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                GlassLink.shared.appDidBecomeActive()
            }
        }
        .alert("Glass paired", isPresented: pairedAlertShown) {
            Button("OK", role: .cancel) {
                GlassLink.shared.justPairedCode = nil
            }
        } message: {
            Text(pairedAlertMessage)
        }
    }

    private var pairedAlertShown: Binding<Bool> {
        return Binding<Bool>(
            get: { GlassLink.shared.justPairedCode != nil },
            set: { newValue in
                if !newValue {
                    GlassLink.shared.justPairedCode = nil
                }
            }
        )
    }

    private var pairedAlertMessage: String {
        let code: String = link.justPairedCode ?? ""
        return "Code " + code + ". Check that Glass shows the same code."
    }
}
