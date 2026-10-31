// GlassBridgeShortcuts.swift - App Shortcuts (Siri and Spotlight) for Send to Glass.

import Foundation
import AppIntents

struct GlassBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendToGlassIntent(),
            phrases: [
                "Send to Glass with \(.applicationName)",
                "Show on Glass with \(.applicationName)"
            ],
            shortTitle: "Send to Glass",
            systemImageName: "eyeglasses"
        )
    }
}
