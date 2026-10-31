// SetupGuideView.swift - step-by-step setup (Tools tab › Setup guide). Every command has a
// Copy button.

import Foundation
import SwiftUI

/// Commands shown in the app (run from the repo root on a computer with adb).
enum SetupCommands {
    static let install: String = "adb install -r dist/GlassBridge-debug.apk"
    static let installHelper: String = "python3 tools/glass_adb.py install"
    static let mockLocation: String = "adb shell settings put secure mock_location 1"
    static let startService: String = "adb shell am startservice -n au.interstellr.glassbridge/.BridgeService"
    static let openApp: String = "adb shell am start -n au.interstellr.glassbridge/.MainActivity"
    static let wifiJSON: String = "python3 tools/glass_adb.py wifi \"My iPhone\" \"hotspot-password\" WPA"
    static let screenshot: String = "adb shell screencap -p /sdcard/s.png && adb pull /sdcard/s.png"
    static let logs: String = "python3 tools/glass_adb.py logs"
    static let fakeGlass: String = "python3 tools/fake_glass.py 172.20.10.1"
}

struct SetupGuideView: View {
    var body: some View {
        List {
            GuideStep(number: 1, title: "Turn on debug mode on Glass",
                      text: "On Glass: Settings › Device info › Turn on debug. Connect Glass to the computer with USB and accept the prompt if one appears.")

            Section {
                StepHeader(number: 2, title: "Install GlassBridge on Glass")
                Text("From the repo on your computer (adb from Android platform-tools):")
                    .font(.footnote)
                CommandRow(command: SetupCommands.install)
                Text("or use the helper, which explains install errors:")
                    .font(.footnote)
                CommandRow(command: SetupCommands.installHelper)
            }

            Section {
                StepHeader(number: 3, title: "Allow mock locations on Glass (once)")
                Text("Glass has no setting for this. Without it Glass can't use the iPhone's GPS (the Glass tab shows Mock location: Off).")
                    .font(.footnote)
                CommandRow(command: SetupCommands.mockLocation)
            }

            GuideStep(number: 4, title: "Turn on Personal Hotspot",
                      text: "On this iPhone: Settings › Personal Hotspot › Allow Others to Join, and turn on Maximize Compatibility. Glass's Wi-Fi is 2.4 GHz only and won't see the hotspot without it. Keep the Personal Hotspot screen open while Glass joins the first time.")

            Section {
                StepHeader(number: 5, title: "Get Glass onto the hotspot")
                Text("Glass needs the hotspot's name and password. Either show a QR code (Tools › Wi-Fi for Glass › Show QR code, then Settings › Wi-Fi on Glass), or push it over adb. Glass reads wifi.json, saves the network and deletes the file:")
                    .font(.footnote)
                CommandRow(command: SetupCommands.wifiJSON)
                Text("Once Glass is linked you can also use Tools › Send to connected Glass for other networks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            GuideStep(number: 6, title: "Allow Local Network on the iPhone",
                      text: "The first time GlassBridge starts, iOS asks to find devices on your local network. Tap Allow. If you declined: Settings › Privacy & Security › Local Network › GlassBridge. The Glass tab's Server row should say Listening on port 9090.")

            Section {
                StepHeader(number: 7, title: "Pair Glass")
                Text(pairingText)
                    .font(.footnote)
                Text("To start over, tap Forget Glass on the Glass tab; Glass then has to pair again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                StepHeader(number: 8, title: "Open GlassBridge on Glass")
                Text("Glass finds the iPhone by itself on the hotspot (the iPhone is the gateway, usually 172.20.10.1). To start or reopen it over adb:")
                    .font(.footnote)
                CommandRow(command: SetupCommands.startService)
                CommandRow(command: SetupCommands.openApp)
            }

            GuideStep(number: 9, title: "Notifications from Messages and Mail",
                      text: "In Shortcuts › Automation, make a Message (or Email) automation set to Run Immediately, add GlassBridge's Send to Glass action, and pass the message as Text. Siri also understands \"Send to Glass with GlassBridge\".")

            Section {
                StepHeader(number: 10, title: "Checking and troubleshooting")
                Text("The event log (Tools tab) records the server state, pairing, connections and transfers. Glass's screen without the mirror lens:")
                    .font(.footnote)
                CommandRow(command: SetupCommands.screenshot)
                Text("Glass logs (including touchpad input):")
                    .font(.footnote)
                CommandRow(command: SetupCommands.logs)
                Text("Testing the iPhone app without Glass: from a laptop on the hotspot, run the fake Glass:")
                    .font(.footnote)
                CommandRow(command: SetupCommands.fakeGlass)
            }
        }
        .navigationTitle("Setup guide")
    }

    private var pairingText: String {
        return "Pairing opens for 2 minutes by itself when the app starts or comes to the front while no Glass is paired; otherwise tap Pair Glass on the Glass tab. With GlassBridge open on Glass, the iPhone shows \"Glass paired\" with a 4-digit code and Glass shows a Paired card. Check that both codes match. If Glass says \"Pair on your iPhone\", tap Pair Glass: Glass retries every 5 seconds."
    }
}

struct StepHeader: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(number))
                .font(.headline)
                .foregroundStyle(Color.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: Circle())
            Text(title)
                .font(.headline)
        }
    }
}

struct GuideStep: View {
    let number: Int
    let title: String
    let text: String

    var body: some View {
        Section {
            StepHeader(number: number, title: title)
            Text(text)
                .font(.footnote)
        }
    }
}
