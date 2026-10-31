// SendToGlassIntent.swift - the Shortcuts "Send to Glass" action.
//
// Paired with Shortcuts › Automation › Message (or Email), this is how iMessage and mail
// notifications reach Glass until ANCS (phase 2). The intent starts the server, sends the
// card (queued for 10 minutes if Glass isn't connected) and answers with a dialog.
// openAppWhenRun is false (deprecated on the iOS 26 SDK: a warning, not an error).

import AppIntents
import Foundation

struct SendToGlassIntent: AppIntent {
    static let title: LocalizedStringResource = "Send to Glass"
    // No `description`: it's optional, and a plain `static var description = IntentDescription(…)`
    // wouldn't witness the IntentDescription? requirement anyway.
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Heading", default: "iPhone")
    var heading: String

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Notify", description: "Chime and wake the Glass display.", default: true)
    var notify: Bool

    @Parameter(title: "Speak Aloud", default: false)
    var speakAloud: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$text) to Glass") {
            \.$heading
            \.$notify
            \.$speakAloud
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let link = GlassLink.shared
        link.start()
        let title: String = heading.gbTrimmed.isEmpty ? "iPhone" : heading.gbTrimmed
        let delivered: Bool = link.sendCard(title: title, text: text, notify: notify,
                                            speak: speakAloud, source: "Shortcuts")
        // Build the String first: a ternary inside .result(dialog:) fails type inference.
        let message: String
        if delivered {
            message = "Sent to Glass."
        } else {
            message = "Glass isn't connected. It'll get this if it reconnects in the next 10 minutes."
        }
        return .result(dialog: "\(message)")
    }
}
