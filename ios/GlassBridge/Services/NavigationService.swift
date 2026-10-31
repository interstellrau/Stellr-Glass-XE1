// NavigationService.swift - Apple Maps search and routing, driving Core's NavTracker.
//
// * Search: MKLocalSearchCompleter (.address and .pointOfInterest, top 8 suggestions),
//   then MKLocalSearch on the chosen suggestion (or the typed text), then MKDirections with
//   walking or automobile transport. `error` is cleared whenever a route succeeds.
// * Guidance: MKRoute.steps (each with >= 2 polyline points) become Core NavSteps; a
//   NavTracker decides what to send. Every location fix goes to tracker.update, a 2 s timer
//   to tracker.tick. .send -> GlassLink.send(card.message()); .reroute -> MKDirections from
//   that point to the same destination with the same transport (on failure do nothing: the
//   tracker asks again after 10 s); .end -> nav_end and stop.
// * Glass reconnect: GlassLink sends currentCardMessage() (never announced).
// * No UIKit here (no idle-timer calls in services).
// ObservableObject singleton, main thread only. Not @MainActor, on purpose.

import Foundation
import Combine
import CoreLocation
import MapKit

/// One search suggestion for the Navigate tab.
struct PlaceSuggestion: Identifiable {
    let id: Int
    let title: String
    let subtitle: String
    let completion: MKLocalSearchCompletion
}

final class NavigationService: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    static let shared = NavigationService()

    static let maxSuggestions: Int = 8
    static let tickInterval: TimeInterval = 2
    static let completerRegionMetres: CLLocationDistance = 50_000
    static let searchRegionMetres: CLLocationDistance = 30_000

    /// The search field's text.
    @Published var query: String = "" {
        didSet {
            if query != oldValue {
                queryChanged()
            }
        }
    }
    @Published private(set) var suggestions: [PlaceSuggestion] = []
    @Published private(set) var destinationName: String?
    @Published private(set) var destinationCoordinate: CLLocationCoordinate2D?
    @Published private(set) var route: MKRoute?
    /// Bumped when a new preview route arrives (the map reframes on it).
    @Published private(set) var previewGeneration: Int = 0
    /// Walk/Drive picker. Changing it recalculates the route (and rebuilds the tracker
    /// during guidance, since a tracker's transport is fixed).
    @Published var transport: NavTransport = .walking {
        didSet {
            if transport != oldValue {
                transportChanged()
            }
        }
    }
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var error: String?

    // Live guidance (drives the on-phone panel).
    @Published private(set) var guiding: Bool = false
    @Published private(set) var liveCard: NavCard?
    @Published private(set) var liveRemainingM: Double?
    @Published private(set) var liveEtaMin: Int?
    @Published private(set) var rerouting: Bool = false

    private(set) var tracker: NavTracker?
    private var destinationItem: MKMapItem?
    private let completer: MKLocalSearchCompleter
    private var search: MKLocalSearch?
    private var previewDirections: MKDirections?
    private var rerouteDirections: MKDirections?
    private var timer: Timer?
    private var searchToken: Int = 0
    private var routeToken: Int = 0
    private var guidanceID: Int = 0
    private var suppressQueryChange: Bool = false

    private override init() {
        completer = MKLocalSearchCompleter()
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
    }

    // MARK: - Search

    private func queryChanged() {
        if suppressQueryChange { return }
        let text: String = query.gbTrimmed
        if text.isEmpty {
            completer.cancel()
            suggestions = []
            return
        }
        if let loc = LocationService.shared.location {
            let metres: CLLocationDistance = NavigationService.completerRegionMetres
            completer.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: metres, longitudinalMeters: metres)
        }
        completer.queryFragment = text
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        if query.gbTrimmed.isEmpty {
            suggestions = []
            return
        }
        let results: [MKLocalSearchCompletion] = Array(completer.results.prefix(NavigationService.maxSuggestions))
        var out: [PlaceSuggestion] = []
        var index: Int = 0
        for r in results {
            out.append(PlaceSuggestion(id: index, title: r.title, subtitle: r.subtitle, completion: r))
            index += 1
        }
        suggestions = out
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
    }

    /// The user picked a suggestion.
    func choose(_ suggestion: PlaceSuggestion) {
        setQuerySilently(suggestion.title)
        suggestions = []
        completer.cancel()
        let request = MKLocalSearch.Request(completion: suggestion.completion)
        runSearch(request, label: suggestion.title)
    }

    /// The user pressed Search on the keyboard: search the typed text.
    func searchTyped() {
        let text: String = query.gbTrimmed
        if text.isEmpty { return }
        suggestions = []
        completer.cancel()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let loc = LocationService.shared.location {
            let metres: CLLocationDistance = NavigationService.searchRegionMetres
            request.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: metres, longitudinalMeters: metres)
        }
        runSearch(request, label: text)
    }

    /// The search field's clear button: text and suggestions only.
    func clearQuery() {
        setQuerySilently("")
        completer.cancel()
        suggestions = []
    }

    private func setQuerySilently(_ text: String) {
        suppressQueryChange = true
        query = text
        suppressQueryChange = false
    }

    private func runSearch(_ request: MKLocalSearch.Request, label: String) {
        search?.cancel()
        searchToken += 1
        let token: Int = searchToken
        let s = MKLocalSearch(request: request)
        search = s
        isBusy = true
        error = nil
        s.start { [weak self] response, searchError in
            guard let self = self, token == self.searchToken else { return }
            self.search = nil
            self.isBusy = false
            guard let item = response?.mapItems.first else {
                self.error = "Couldn't find “" + label + "”."
                return
            }
            let name: String = item.name ?? label
            self.setDestination(item, name: name)
        }
    }

    private func setDestination(_ item: MKMapItem, name: String) {
        if tracker != nil {
            endGuidance()
        }
        destinationItem = item
        destinationName = name
        destinationCoordinate = item.placemark.coordinate
        route = nil
        calculatePreviewRoute()
    }

    /// Clear button: forget the destination and route (ends guidance if active).
    func clear() {
        if tracker != nil {
            endGuidance()
        }
        search?.cancel()
        search = nil
        previewDirections?.cancel()
        previewDirections = nil
        searchToken += 1
        routeToken += 1
        destinationItem = nil
        destinationName = nil
        destinationCoordinate = nil
        route = nil
        error = nil
        isBusy = false
        clearQuery()
    }

    // MARK: - Routing

    private func calculatePreviewRoute() {
        guard let destination = destinationItem else { return }
        routeToken += 1
        let token: Int = routeToken
        isBusy = true
        error = nil
        previewDirections?.cancel()
        previewDirections = calculate(from: currentSource(), to: destination, transport: transport) { [weak self] newRoute, message in
            guard let self = self, token == self.routeToken else { return }
            self.isBusy = false
            self.previewDirections = nil
            if let r = newRoute {
                self.route = r
                self.error = nil
                self.previewGeneration += 1
            } else {
                self.route = nil
                self.error = message
            }
        }
    }

    /// Asks MapKit for a route. The completion runs on the main thread.
    private func calculate(from source: MKMapItem, to destination: MKMapItem, transport: NavTransport,
                           completion: @escaping (MKRoute?, String?) -> Void) -> MKDirections {
        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        let type: MKDirectionsTransportType = (transport == .walking) ? .walking : .automobile
        request.transportType = type
        request.requestsAlternateRoutes = false
        let directions = MKDirections(request: request)
        directions.calculate { response, directionsError in
            let first: MKRoute? = response?.routes.first
            var message: String? = nil
            if first == nil {
                if let e = directionsError {
                    message = e.localizedDescription
                } else {
                    message = "No route found."
                }
            }
            let failure: String? = message
            DispatchQueue.main.async {
                completion(first, failure)
            }
        }
        return directions
    }

    private func currentSource() -> MKMapItem {
        if let loc = LocationService.shared.location {
            return NavigationService.mapItem(at: loc.coordinate)
        }
        return MKMapItem.forCurrentLocation()
    }

    static func mapItem(at coordinate: CLLocationCoordinate2D) -> MKMapItem {
        return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    }

    /// MKRoute steps as Core NavSteps (steps with fewer than 2 points are dropped; Core
    /// drops them too).
    static func steps(from route: MKRoute) -> [NavStep] {
        var out: [NavStep] = []
        for step in route.steps {
            let n: Int = step.polyline.pointCount
            if n < 2 { continue }
            var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: n)
            step.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
            var points: [GeoPoint] = []
            points.reserveCapacity(n)
            for c in coords {
                points.append(GeoPoint(lat: c.latitude, lon: c.longitude))
            }
            out.append(NavStep(instruction: step.instructions, points: points, distance: step.distance))
        }
        return out
    }

    private func transportChanged() {
        guard let destination = destinationItem else { return }
        guard let old = tracker, old.isActive else {
            calculatePreviewRoute()
            return
        }
        // During guidance: new route with the new transport, then a new tracker.
        let wasDeparted: Bool = old.departed
        let newTransport: NavTransport = transport
        let id: Int = guidanceID
        isBusy = true
        rerouteDirections?.cancel()
        rerouteDirections = calculate(from: currentSource(), to: destination, transport: newTransport) { [weak self] newRoute, message in
            guard let self = self else { return }
            self.isBusy = false
            self.rerouteDirections = nil
            guard id == self.guidanceID, self.tracker != nil else { return }
            guard let r = newRoute else {
                self.error = message
                return
            }
            self.route = r
            self.error = nil
            let steps: [NavStep] = NavigationService.steps(from: r)
            let next = NavTracker(steps: steps, transport: newTransport, destinationName: self.destinationName,
                                  expectedTravelTime: r.expectedTravelTime, departed: wasDeparted)
            if next.isActive {
                self.beginGuidance(with: next)
            }
        }
    }

    // MARK: - Guidance

    /// Start on Glass.
    func startGuidance() {
        guard let r = route else { return }
        let steps: [NavStep] = NavigationService.steps(from: r)
        let t = NavTracker(steps: steps, transport: transport, destinationName: destinationName,
                           expectedTravelTime: r.expectedTravelTime)
        guard t.isActive else {
            error = "This route has no steps to follow."
            return
        }
        beginGuidance(with: t)
    }

    private func beginGuidance(with t: NavTracker) {
        timer?.invalidate()
        timer = nil
        tracker?.stop()
        guidanceID += 1
        tracker = t
        guiding = true
        rerouting = false
        error = nil
        LocationService.shared.navigating = true
        let name: String = destinationName ?? "the destination"
        GlassLink.shared.log("Guidance started to " + name)

        let now: TimeInterval = Date().timeIntervalSince1970
        perform(t.start(now: now, at: currentGeoPoint()))
        refreshLive()

        let tick = Timer(timeInterval: NavigationService.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    /// End button.
    func endGuidance() {
        guard let t = tracker else { return }
        t.stop()
        GlassLink.shared.send(Msg.navEnd())
        GlassLink.shared.log("Guidance ended")
        finishGuidance()
    }

    private func finishGuidance() {
        timer?.invalidate()
        timer = nil
        rerouteDirections?.cancel()
        rerouteDirections = nil
        tracker = nil
        guidanceID += 1
        guiding = false
        rerouting = false
        isBusy = false
        refreshLive()
        LocationService.shared.navigating = false
    }

    /// Every location fix (LocationService calls this unthrottled).
    func handleFix(_ location: CLLocation) {
        guard let t = tracker, location.horizontalAccuracy >= 0 else { return }
        let point = GeoPoint(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
        perform(t.update(fix: point, now: Date().timeIntervalSince1970))
        refreshLive()
    }

    private func tick() {
        guard let t = tracker else { return }
        perform(t.tick(now: Date().timeIntervalSince1970))
        refreshLive()
    }

    private func perform(_ actions: [NavAction]) {
        for action in actions {
            switch action {
            case .send(let card):
                GlassLink.shared.send(card.message())
                liveCard = card
            case .reroute(let from):
                reroute(from: from)
            case .end:
                GlassLink.shared.send(Msg.navEnd())
                GlassLink.shared.log("Arrived: guidance ended")
                finishGuidance()
            }
        }
    }

    private func reroute(from point: GeoPoint) {
        guard let destination = destinationItem, let t = tracker, !rerouting else { return }
        rerouting = true
        let id: Int = guidanceID
        let coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
        GlassLink.shared.log("Off route: asking Apple Maps for a new route")
        rerouteDirections?.cancel()
        rerouteDirections = calculate(from: NavigationService.mapItem(at: coordinate), to: destination,
                                      transport: t.transport) { [weak self] newRoute, message in
            guard let self = self else { return }
            self.rerouting = false
            self.rerouteDirections = nil
            guard id == self.guidanceID, let current = self.tracker, current.isActive else { return }
            guard let r = newRoute else {
                // Keep going; the tracker asks again after 10 s while still off route.
                let reason: String = message ?? "no route"
                GlassLink.shared.log("Reroute failed: " + reason)
                return
            }
            self.route = r
            self.error = nil
            let steps: [NavStep] = NavigationService.steps(from: r)
            let now: TimeInterval = Date().timeIntervalSince1970
            self.perform(current.replaceRoute(steps: steps, expectedTravelTime: r.expectedTravelTime, now: now))
            self.refreshLive()
        }
    }

    private func refreshLive() {
        guard let t = tracker else {
            liveCard = nil
            liveRemainingM = nil
            liveEtaMin = nil
            return
        }
        if let card = t.lastCard {
            liveCard = card
        }
        liveRemainingM = t.remainingDistance
        liveEtaMin = t.etaMinutes
    }

    private func currentGeoPoint() -> GeoPoint? {
        guard let loc = LocationService.shared.location else { return nil }
        return GeoPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
    }

    /// The current nav card for a reconnecting Glass (announce is always false).
    func currentCardMessage() -> GBObject? {
        guard let card = tracker?.currentCard() else { return nil }
        return card.message()
    }
}
