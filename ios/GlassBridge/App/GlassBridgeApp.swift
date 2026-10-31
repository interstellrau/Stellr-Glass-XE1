// GlassBridgeApp.swift - app entry point.
//
// GlassLink.shared.start() runs in init, so a background launch (for example the Shortcuts
// "Send to Glass" action) brings the server up too. ContentView calls
// GlassLink.shared.appDidBecomeActive() whenever the scene becomes active, which restarts
// a listener iOS tore down while suspended and opens pairing while no Glass is paired.

import Foundation
import SwiftUI

@main
struct GlassBridgeApp: App {
    init() {
        let link = GlassLink.shared
        link.start()
        // PROTOCOL.md section 6: pairing opens on launch while nothing is paired.
        link.openPairingWindowIfUnpaired()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
