// NavigateTab.swift - map with the user, route and destination; a search field with
// suggestions; and one bottom panel (inside a single VStack, so it draws one bar) with
// either the route preview or the live guidance.

import Foundation
import SwiftUI
import MapKit

struct NavigateTab: View {
    @ObservedObject private var nav = NavigationService.shared
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        RouteMap(camera: $camera)
            .safeAreaInset(edge: .top) {
                SearchPanel()
            }
            .safeAreaInset(edge: .bottom) {
                BottomPanel()
            }
            .onChange(of: nav.previewGeneration) { _, _ in
                frameRoute()
            }
            .onChange(of: nav.guiding) { _, isGuiding in
                if isGuiding {
                    camera = .userLocation(followsHeading: true, fallback: .automatic)
                } else {
                    frameRoute()
                }
            }
    }

    private func frameRoute() {
        guard let route = nav.route else { return }
        let rect: MKMapRect = route.polyline.boundingMapRect
        let padded: MKMapRect = rect.insetBy(dx: -rect.size.width * 0.2, dy: -rect.size.height * 0.2)
        camera = .rect(padded)
    }
}

struct RouteMap: View {
    @ObservedObject var nav: NavigationService = NavigationService.shared
    @Binding var camera: MapCameraPosition

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
            if let route = nav.route {
                MapPolyline(route.polyline)
                    .stroke(Color.blue, lineWidth: 6)
            }
            if let destination = nav.destinationCoordinate {
                Marker(destinationTitle, coordinate: destination)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
    }

    private var destinationTitle: String {
        return nav.destinationName ?? "Destination"
    }
}

// MARK: - Search

struct SearchPanel: View {
    @ObservedObject private var nav = NavigationService.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search for a place or address", text: $nav.query)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit {
                        focused = false
                        nav.searchTyped()
                    }
                if !nav.query.isEmpty {
                    Button {
                        nav.clearQuery()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            if focused && !nav.suggestions.isEmpty {
                SuggestionList(onPick: { suggestion in
                    focused = false
                    nav.choose(suggestion)
                })
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}

struct SuggestionList: View {
    @ObservedObject var nav: NavigationService = NavigationService.shared
    let onPick: (PlaceSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(nav.suggestions) { suggestion in
                SuggestionRow(suggestion: suggestion, onPick: onPick)
                Divider()
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 6)
    }
}

struct SuggestionRow: View {
    let suggestion: PlaceSuggestion
    let onPick: (PlaceSuggestion) -> Void

    var body: some View {
        Button {
            onPick(suggestion)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .foregroundStyle(.primary)
                if !suggestion.subtitle.isEmpty {
                    Text(suggestion.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bottom panel

struct BottomPanel: View {
    @ObservedObject private var nav = NavigationService.shared

    var body: some View {
        if showsPanel {
            // One VStack, so .padding().background(.bar) draws a single bar.
            VStack(alignment: .leading, spacing: 12) {
                if nav.guiding {
                    LiveGuidancePanel()
                } else {
                    RoutePreviewPanel()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    private var showsPanel: Bool {
        if nav.guiding { return true }
        if nav.route != nil || nav.isBusy { return true }
        return nav.error != nil || nav.destinationName != nil
    }
}

struct RoutePreviewPanel: View {
    @ObservedObject private var nav = NavigationService.shared
    @ObservedObject private var link = GlassLink.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let name = nav.destinationName {
                Text(name)
                    .font(.headline)
                    .lineLimit(2)
            }
            if nav.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding a route…")
                        .foregroundStyle(.secondary)
                }
            }
            if let message = nav.error {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let summary = routeSummary {
                Text(summary)
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            Picker("Transport", selection: $nav.transport) {
                Text("Walk").tag(NavTransport.walking)
                Text("Drive").tag(NavTransport.driving)
            }
            .pickerStyle(.segmented)
            HStack {
                Button("Clear", role: .destructive) {
                    nav.clear()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    nav.startGuidance()
                } label: {
                    Label("Start on Glass", systemImage: "eyeglasses")
                }
                .buttonStyle(.borderedProminent)
                .disabled(nav.route == nil)
            }
            if nav.route != nil && !link.connected {
                Text("Glass isn't connected. Guidance still starts, and Glass gets the current turn when it connects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var routeSummary: String? {
        guard let r = nav.route else { return nil }
        return GBFormat.duration(r.expectedTravelTime) + " · " + GBFormat.distance(r.distance)
    }
}

struct LiveGuidancePanel: View {
    @ObservedObject private var nav = NavigationService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: maneuverSymbol)
                    .font(.system(size: 34, weight: .semibold))
                    .frame(width: 44)
                Text(distanceText)
                    .font(.system(size: 34, weight: .bold))
            }
            Text(instructionText)
                .font(.title3)
                .lineLimit(3)
            Text(remainingText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if nav.rerouting {
                Text("Rerouting…")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button(role: .destructive) {
                nav.endGuidance()
            } label: {
                Label("End", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.red)
        }
    }

    private var distanceText: String {
        guard let card = nav.liveCard else { return "–" }
        if card.arrived { return "Arrived" }
        return GBFormat.distance(card.distanceM)
    }

    private var instructionText: String {
        guard let card = nav.liveCard else { return "Starting guidance…" }
        return card.instruction
    }

    private var remainingText: String {
        var parts: [String] = []
        if let remaining = nav.liveRemainingM {
            parts.append(GBFormat.distance(remaining) + " left")
        }
        if let eta = nav.liveEtaMin {
            parts.append(GBFormat.minutes(eta))
        }
        if let card = nav.liveCard {
            parts.append("step " + String(card.step) + " of " + String(card.stepsTotal))
        }
        return parts.joined(separator: " · ")
    }

    private var maneuverSymbol: String {
        guard let card = nav.liveCard else { return "location.north.fill" }
        return ManeuverSymbol.name(for: card.maneuver)
    }
}

/// SF Symbol for each nav maneuver.
enum ManeuverSymbol {
    static func name(for maneuver: Maneuver) -> String {
        switch maneuver {
        case .depart: return "location.north.fill"
        case .straight: return "arrow.up"
        case .left: return "arrow.turn.up.left"
        case .right: return "arrow.turn.up.right"
        case .slightLeft: return "arrow.up.left"
        case .slightRight: return "arrow.up.right"
        case .sharpLeft: return "arrow.down.left"
        case .sharpRight: return "arrow.down.right"
        case .uturn: return "arrow.uturn.down"
        case .arrive: return "mappin.circle.fill"
        }
    }
}
