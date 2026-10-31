// GlassTab.swift - link state, pairing, Glass status, Find my Glass and the main toggles.
// Pull to refresh sends request_status.

import Foundation
import SwiftUI
import MapKit
import UIKit

struct GlassTab: View {
    var body: some View {
        NavigationStack {
            Form {
                LinkSection()
                PairingSection()
                StatusSection()
                FindMyGlassSection()
                GlassSettingsSection()
            }
            .navigationTitle("Glass")
            .refreshable {
                await MainActor.run {
                    GlassLink.shared.requestStatus()
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }
}

// MARK: - Link

struct LinkSection: View {
    @ObservedObject private var link = GlassLink.shared

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            LabeledContent("Server", value: link.listenerState)
            if !link.listenerReady {
                Text(listenerHint)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if link.queuedCardCount > 0 {
                LabeledContent("Queued cards", value: String(link.queuedCardCount))
            }
        } header: {
            Text("Link")
        }
    }

    private var dotColor: Color {
        if link.connected { return Color.green }
        return link.listenerReady ? Color.orange : Color.red
    }

    private var title: String {
        return link.connected ? "Connected to Glass" : "Waiting for Glass"
    }

    private var subtitle: String {
        if link.connected {
            let address: String = link.remoteAddress ?? "unknown address"
            var text: String = "From " + address
            if let since = link.connectedSince {
                text += " since " + GBFormat.clock(since)
            }
            return text
        }
        return "Glass dials this iPhone on port 9090 (Personal Hotspot: 172.20.10.1)."
    }

    private var listenerHint: String {
        return "If this doesn't say Listening, allow Local Network for GlassBridge in Settings › Privacy & Security › Local Network, then reopen the app."
    }
}

// MARK: - Pairing

struct PairingSection: View {
    @ObservedObject private var link = GlassLink.shared
    @State private var confirmForget: Bool = false

    var body: some View {
        Section {
            TimelineView(.periodic(from: Date(), by: 1.0)) { context in
                PairingStateRow(text: link.pairingStateText(now: context.date.timeIntervalSince1970))
            }
            if let code = link.pairing.lastPairCode {
                PairCodeRow(code: code)
            }
            if !link.connected, let rejection = link.lastRejection {
                Text(rejection)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button {
                link.openPairingWindow()
            } label: {
                Label("Pair Glass", systemImage: "link")
            }
            Button(role: .destructive) {
                confirmForget = true
            } label: {
                Label("Forget Glass", systemImage: "trash")
            }
            .disabled(!link.pairing.isPaired)
            .confirmationDialog("Forget the paired Glass?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget Glass", role: .destructive) {
                    link.forgetGlass()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Glass is disconnected and has to be paired again before it can connect.")
            }
        } header: {
            Text("Pairing")
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        return "Pair Glass opens pairing for 2 minutes (it also opens by itself when the app starts or comes to the front while nothing is paired). Make sure Glass has the GlassBridge app open and is on the same network or your Personal Hotspot. Both screens then show the same 4-digit code."
    }
}

struct PairingStateRow: View {
    let text: String

    var body: some View {
        LabeledContent("State", value: text)
    }
}

struct PairCodeRow: View {
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Code")
                Spacer()
                Text(code)
                    .font(.system(.title2, design: .monospaced))
                    .fontWeight(.semibold)
            }
            Text("Check that Glass shows the same code.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Status

struct StatusSection: View {
    @ObservedObject private var link = GlassLink.shared

    var body: some View {
        Section {
            if let device = link.device {
                LabeledContent("Model", value: device.model ?? "Unknown")
                LabeledContent("Firmware", value: device.firmware ?? "Unknown")
                LabeledContent("App version", value: device.appVersion ?? "Unknown")
            }
            if let s = link.status {
                LabeledContent("Battery", value: StatusText.battery(s))
                LabeledContent("Storage", value: StatusText.storage(s))
                LabeledContent("Wi-Fi", value: StatusText.wifi(s))
                LabeledContent("Screen", value: StatusText.screen(s))
                LabeledContent("Uptime", value: StatusText.uptime(s))
                MockLocationRow(enabled: s.mockLocation ?? false)
            } else {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Status")
        } footer: {
            Text(footerText)
        }
    }

    private var emptyText: String {
        return link.connected ? "Waiting for Glass to send its status." : "Connect Glass to see its battery, storage and Wi-Fi."
    }

    private var footerText: String {
        guard let t = link.statusTime else { return "Pull down to ask Glass for its status." }
        return "Updated " + GBFormat.clock(t) + ". Pull down to refresh."
    }
}

/// Status strings, built outside Text() so SwiftUI type-checks quickly.
enum StatusText {
    static func battery(_ s: GlassStatus) -> String {
        guard let b = s.battery else { return "Unknown" }
        var text: String = String(b) + "%"
        if s.charging == true {
            text += ", charging"
        }
        return text
    }

    static func storage(_ s: GlassStatus) -> String {
        guard let free = s.storageFreeMB else { return "Unknown" }
        var text: String = GBFormat.megabytes(free) + " free"
        if let total = s.storageTotalMB {
            text += " of " + GBFormat.megabytes(total)
        }
        return text
    }

    static func wifi(_ s: GlassStatus) -> String {
        guard let ssid = s.wifiSSID, !ssid.isEmpty else { return "Not connected" }
        var text: String = ssid
        if let rssi = s.wifiRSSI {
            text += " (" + String(rssi) + " dBm)"
        }
        return text
    }

    static func screen(_ s: GlassStatus) -> String {
        guard let on = s.screenOn else { return "Unknown" }
        return on ? "On" : "Off"
    }

    static func uptime(_ s: GlassStatus) -> String {
        guard let u = s.uptimeS else { return "Unknown" }
        return GBFormat.uptime(u)
    }
}

struct MockLocationRow: View {
    let enabled: Bool

    var body: some View {
        if enabled {
            LabeledContent("Mock location", value: "On")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Mock location", value: "Off")
                Text("Glass can't use the iPhone's GPS until you run this once with Glass on USB:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                CommandRow(command: SetupCommands.mockLocation)
            }
        }
    }
}

/// A monospaced, selectable command with a Copy button.
struct CommandRow: View {
    let command: String
    @State private var copied: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = command
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy command")
        }
        .padding(8)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Find my Glass

struct FindMyGlassSection: View {
    @ObservedObject private var link = GlassLink.shared

    var body: some View {
        Section {
            LabeledContent("Last seen", value: lastSeenText)
            if let c = link.lastSeenCoordinate {
                FindMyGlassMap(coordinate: c)
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
            } else {
                Text("No location yet. It's recorded while Glass is connected and the iPhone knows where it is.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Find my Glass")
        } footer: {
            Text("The iPhone's position the last time Glass was connected.")
        }
    }

    private var lastSeenText: String {
        if link.connected { return "Now (connected)" }
        guard let seen = link.lastSeen else { return "Never" }
        return GBFormat.dateTime(seen) + " (" + GBFormat.relative(seen) + ")"
    }
}

/// Map(initialPosition:) applies only once, so .id("lat,lon") recreates it when the
/// coordinate changes.
struct FindMyGlassMap: View {
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        Map(initialPosition: initialPosition) {
            Marker(markerTitle, coordinate: coordinate)
        }
        .id(mapID)
    }

    private var initialPosition: MapCameraPosition {
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 600, longitudinalMeters: 600)
        return MapCameraPosition.region(region)
    }

    private var markerTitle: String {
        return "Glass"
    }

    private var mapID: String {
        return String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
    }
}

// MARK: - Settings

struct GlassSettingsSection: View {
    @ObservedObject private var link = GlassLink.shared
    @ObservedObject private var location = LocationService.shared

    var body: some View {
        Section {
            Toggle("Save photos", isOn: $link.syncEnabled)
            Toggle("Share location", isOn: $link.shareLocation)
            Toggle("Stay connected in background", isOn: $link.stayAlive)
            LabeledContent("Location access", value: location.authorizationText)
            LabeledContent("Location mode", value: location.mode.rawValue)
        } header: {
            Text("Settings")
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        return "Save photos lets Glass upload new photos and videos to your library. Share location sends the iPhone's GPS to Glass. While either location toggle is on, GlassBridge keeps running in the background (blue location indicator) so Glass stays connected when the iPhone is locked."
    }
}
