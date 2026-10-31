// ToolsTab.swift - send a card, Wi-Fi setup (QR code or wifi_add), the name shown on Glass,
// the setup guide and the event log.

import Foundation
import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct ToolsTab: View {
    var body: some View {
        NavigationStack {
            Form {
                SendCardSection()
                WiFiSection()
                PhoneNameSection()
                GuideAndLogSection()
            }
            .navigationTitle("Tools")
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

// MARK: - Send a card

struct SendCardSection: View {
    @State private var heading: String = ""
    @State private var cardText: String = ""
    @State private var notify: Bool = true
    @State private var speak: Bool = false
    @State private var result: String?

    var body: some View {
        Section {
            TextField("Heading", text: $heading)
            TextField("Text", text: $cardText, axis: .vertical)
                .lineLimit(2...6)
            Toggle("Chime and wake", isOn: $notify)
            Toggle("Also speak", isOn: $speak)
            Button {
                send()
            } label: {
                Label("Send to Glass", systemImage: "paperplane")
            }
            .disabled(cardText.gbTrimmed.isEmpty)
            if let r = result {
                Text(r)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Send a card")
        }
    }

    private func send() {
        let title: String = heading.gbTrimmed.isEmpty ? "iPhone" : heading.gbTrimmed
        let text: String = cardText.gbTrimmed
        let delivered: Bool = GlassLink.shared.sendCard(title: title, text: text, notify: notify,
                                                        speak: speak, source: "iPhone")
        if delivered {
            result = "Sent."
            cardText = ""
        } else {
            result = "Glass isn't connected. It'll get this if it reconnects in the next 10 minutes."
        }
    }
}

// MARK: - Wi-Fi

struct WiFiSection: View {
    @ObservedObject private var link = GlassLink.shared
    @State private var ssid: String = ""
    @State private var password: String = ""
    @State private var security: WiFiSecurity = .wpa
    @State private var showQR: Bool = false

    var body: some View {
        Section {
            TextField("Network name (SSID)", text: $ssid)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if security != .open {
                SecureField("Password", text: $password)
            }
            Picker("Security", selection: $security) {
                Text("WPA/WPA2").tag(WiFiSecurity.wpa)
                Text("WEP").tag(WiFiSecurity.wep)
                Text("Open").tag(WiFiSecurity.open)
            }
            Button {
                showQR = true
            } label: {
                Label("Show QR code", systemImage: "qrcode")
            }
            .disabled(ssid.isEmpty)
            .sheet(isPresented: $showQR) {
                WiFiQRSheet(ssid: ssid, payload: qrPayload)
            }
            Button {
                link.sendWiFi(ssid: ssid, password: password, security: security)
            } label: {
                Label("Send to connected Glass", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(ssid.isEmpty || !link.connected)
            if let r = link.lastWiFiResult {
                Text(r)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Wi-Fi for Glass")
        } footer: {
            Text("Glass Wi-Fi is 2.4 GHz only. For your Personal Hotspot, turn on Maximize Compatibility. Your hotspot's name is in Settings › General › About › Name.")
        }
    }

    private var qrPayload: String {
        return WiFiQR.payload(ssid: ssid, password: password, security: security)
    }
}

struct WiFiQRSheet: View {
    let ssid: String
    let payload: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let image = GBQRCode.image(for: payload) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 320)
                            .padding(12)
                            .background(Color.white)
                    } else {
                        Text("Couldn't make the QR code.")
                    }
                    Text(ssid)
                        .font(.headline)
                    Text("On Glass, open Settings › Wi-Fi and look at this code. XE24 may no longer have the Wi-Fi QR scanner: if nothing happens, push wifi.json over adb (see the setup guide) or use Send to connected Glass once linked.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("Wi-Fi QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// QR codes with Core Image (CIQRCodeGenerator), scaled up without smoothing.
enum GBQRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled: CIImage = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Name shown on Glass

struct PhoneNameSection: View {
    @ObservedObject private var link = GlassLink.shared

    var body: some View {
        Section {
            TextField("Name shown on Glass", text: $link.phoneName)
                .autocorrectionDisabled()
        } header: {
            Text("Name shown on Glass")
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        let device: String = GlassLink.deviceName()
        return "Sent to Glass when it connects (it shows in the Glass footer and the Paired card). Leave it empty to use “" + device + "”. iOS only tells apps a generic device name, so set your own here."
    }
}

// MARK: - Guide and log

struct GuideAndLogSection: View {
    @ObservedObject private var link = GlassLink.shared

    var body: some View {
        Section {
            NavigationLink {
                SetupGuideView()
            } label: {
                Label("Setup guide", systemImage: "list.number")
            }
            NavigationLink {
                EventLogView()
            } label: {
                Label(logTitle, systemImage: "text.alignleft")
            }
            ForEach(recentEntries) { entry in
                LogRow(entry: entry)
            }
        } header: {
            Text("Help and event log")
        }
    }

    private var logTitle: String {
        return "Event log (" + String(link.eventLog.count) + ")"
    }

    private var recentEntries: [LogEntry] {
        return Array(link.eventLog.suffix(3).reversed())
    }
}

struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(GBFormat.clock(entry.time))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(entry.text)
                .font(.footnote)
                .textSelection(.enabled)
        }
    }
}

struct EventLogView: View {
    @ObservedObject private var link = GlassLink.shared

    var body: some View {
        List {
            if link.eventLog.isEmpty {
                Text("Nothing logged yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(newestFirst) { entry in
                LogRow(entry: entry)
            }
        }
        .navigationTitle("Event log")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = GlassLink.shared.eventLogText
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var newestFirst: [LogEntry] {
        return Array(link.eventLog.reversed())
    }
}
