// LocationService.swift - phone GPS for Glass, navigation and the background keep-alive.
//
// iOS suspends apps seconds after they leave the foreground, which freezes the TCP link.
// An app receiving location updates under the `location` background mode keeps running
// (with the blue indicator). The mode is picked automatically:
//
//   | Mode            | When                          | Settings                                   |
//   | Navigating      | guidance active               | BestForNavigation, filter 5 m,             |
//   |                 |                               | .otherNavigation, background on            |
//   | Keep-alive      | stayAlive or shareLocation on | HundredMeters, filter 25 m, background on  |
//   | Foreground only | otherwise                     | as keep-alive, background off, auto-pause  |
//
// When-In-Use permission is requested the first time the app is active. Fixes with a
// negative accuracy are dropped. Glass gets at most one fix every 5 s or 15 m, whichever
// comes first; navigation gets every fix.
// ObservableObject singleton, main thread only (CLLocationManager is created on main, so
// its delegate callbacks arrive on main). Not @MainActor, on purpose.

import Foundation
import Combine
import CoreLocation

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    enum Mode: String {
        case navigating = "Navigating"
        case keepAlive = "Keep-alive"
        case foregroundOnly = "Foreground only"
    }

    /// Glass gets a fix when 5 s have passed or the phone moved 15 m.
    static let glassMinInterval: TimeInterval = 5
    static let glassMinDistance: CLLocationDistance = 15

    @Published private(set) var location: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var mode: Mode = .foregroundOnly

    /// Set by NavigationService while guidance is active.
    var navigating: Bool = false {
        didSet {
            if navigating != oldValue {
                refreshMode()
            }
        }
    }

    private let manager: CLLocationManager
    private var started: Bool = false
    private var updating: Bool = false
    private var modeApplied: Bool = false
    private var lastGlassFix: CLLocation?
    private var lastGlassTime: Date?

    private override init() {
        let m = CLLocationManager()
        manager = m
        authorization = m.authorizationStatus
        super.init()
        m.delegate = self
    }

    // MARK: - Control

    func start() {
        if started { return }
        started = true
        refreshMode()
    }

    /// When-In-Use on first launch (call while the app is active).
    func requestPermissionIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Picks the mode from navigation and the Glass tab's toggles.
    func refreshMode() {
        let link = GlassLink.shared
        let newMode: Mode
        if navigating {
            newMode = .navigating
        } else if link.stayAlive || link.shareLocation {
            newMode = .keepAlive
        } else {
            newMode = .foregroundOnly
        }
        apply(newMode)
    }

    var isAuthorized: Bool {
        let s: CLAuthorizationStatus = manager.authorizationStatus
        return s == .authorizedWhenInUse || s == .authorizedAlways
    }

    var authorizationText: String {
        switch authorization {
        case .notDetermined:
            return "Not asked yet"
        case .restricted:
            return "Restricted"
        case .denied:
            return "Denied (Settings › GlassBridge › Location)"
        case .authorizedAlways:
            return "Always"
        case .authorizedWhenInUse:
            return "While using the app"
        @unknown default:
            return "Unknown"
        }
    }

    /// Sends the newest fix right away (used when Glass connects).
    func sendLatestFixToGlass() {
        guard let loc = location else { return }
        if GlassLink.shared.sendLocation(loc) {
            lastGlassFix = loc
            lastGlassTime = Date()
        }
    }

    private func apply(_ newMode: Mode) {
        switch newMode {
        case .navigating:
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = 5
            manager.activityType = .otherNavigation
            manager.pausesLocationUpdatesAutomatically = false
            // Needs UIBackgroundModes = [location] in Info.plist, or this crashes.
            manager.allowsBackgroundLocationUpdates = true
        case .keepAlive:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 25
            manager.activityType = .other
            manager.pausesLocationUpdatesAutomatically = false
            manager.allowsBackgroundLocationUpdates = true
        case .foregroundOnly:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 25
            manager.activityType = .other
            manager.allowsBackgroundLocationUpdates = false
            manager.pausesLocationUpdatesAutomatically = true
        }
        let changed: Bool = !modeApplied || newMode != mode
        modeApplied = true
        mode = newMode
        updateRunning()
        if changed {
            GlassLink.shared.log("Location mode: " + newMode.rawValue)
        }
    }

    private func updateRunning() {
        if !started { return }
        if isAuthorized {
            // Calling this again is harmless and applies changed settings.
            manager.startUpdatingLocation()
            updating = true
        } else if updating {
            manager.stopUpdatingLocation()
            updating = false
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        updateRunning()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations where loc.horizontalAccuracy >= 0 {
            handle(loc)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError, clError.code == .locationUnknown {
            return // transient: Core Location keeps trying
        }
        GlassLink.shared.log("Location error: " + error.localizedDescription)
    }

    // MARK: - Fixes

    private func handle(_ loc: CLLocation) {
        location = loc
        // Navigation gets every fix.
        NavigationService.shared.handleFix(loc)
        GlassLink.shared.phoneFix(loc)
        if shouldSendToGlass(loc) {
            if GlassLink.shared.sendLocation(loc) {
                lastGlassFix = loc
                lastGlassTime = Date()
            }
        }
    }

    private func shouldSendToGlass(_ loc: CLLocation) -> Bool {
        guard let last = lastGlassFix, let time = lastGlassTime else { return true }
        if Date().timeIntervalSince(time) >= LocationService.glassMinInterval {
            return true
        }
        return loc.distance(from: last) >= LocationService.glassMinDistance
    }
}
