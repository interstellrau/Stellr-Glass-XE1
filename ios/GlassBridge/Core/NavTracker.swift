// NavTracker.swift - GlassBridge Core (Foundation only; builds on Linux for tools/swift-check)
//
// Turn-by-turn progress along a route, as pure logic: no CoreLocation, no MapKit, no
// timers. The app converts MKRoute steps and CLLocation fixes into the plain types below
// and passes "now" in, so every rule here is unit-tested on Linux (tools/swift-check).
//
// HOW NavigationService DRIVES IT
//
//   Start guidance (user taps Start on Glass):
//       let steps: [NavStep] = route.steps.map { s in
//           NavStep(instruction: s.instructions,
//                   points: <s.polyline's coordinates as GeoPoint(lat:lon:)>,
//                   distance: s.distance) }
//       tracker = NavTracker(steps: steps, transport: .walking or .driving,
//                            destinationName: <destination name>,
//                            expectedTravelTime: route.expectedTravelTime)
//       perform(tracker.start(now: now, at: <current position as GeoPoint, if known>))
//                                                  // sends the depart card at once
//
//   Every location fix while navigating (navigation gets every fix, no throttling):
//       perform(tracker.update(fix: GeoPoint(lat: c.latitude, lon: c.longitude), now: now))
//
//   A repeating 1-5 s Timer while guidance is active (keeps the 15 s re-send and the
//   20 s arrival hold going when fixes stop):
//       perform(tracker.tick(now: now))
//
//   perform(actions):
//       .send(card)        -> GlassLink.send(card.message()); update the on-phone panel
//       .reroute(from: p)  -> MKDirections from p to the same destination, same transport.
//                             On success: perform(tracker.replaceRoute(steps: newSteps,
//                             expectedTravelTime: newRoute.expectedTravelTime, now: now)),
//                             show the new polyline and clear `error`. On failure: keep
//                             going; the tracker asks again after 10 s if still off route.
//       .end               -> GlassLink.send(Msg.navEnd()); stop guidance (tracker = nil)
//
//   Glass reconnects (GlassLink's accepted-hello path, after sync/screencast/cards):
//       if let card = tracker?.currentCard() { GlassLink.send(card.message()) }
//       (currentCard() always has announce == false, so Glass doesn't speak again.)
//
//   User taps End:  tracker?.stop(); GlassLink.send(Msg.navEnd()); tracker = nil.
//
//   Use one clock for every `now` (e.g. Date().timeIntervalSince1970). Transport type is
//   fixed per tracker (create a new tracker if the user switches Walk/Drive).
//
// RULES (from the build brief)
//   * Legs: every step with >= 2 points. A step's instruction is the maneuver at its start.
//   * Matching: project each fix onto the current leg and up to 2 legs ahead, never
//     backwards; haversine distance + a local flat projection per segment; the current
//     leg gets a 1 m bias.
//   * Off route: > 50 m from the route for 3 fixes in a row -> .reroute(from: fix), at most
//     once every 10 s. Off-route fixes don't move the tracker along the route.
//   * Depart: until the user has moved 30 m from where guidance started (the position
//     passed to start(now:at:), else the first fix), show the depart step
//     (step 1). After that, show the next maneuver with the distance left on the current
//     leg. `step` is 1-based out of legs + 1 (the last one is the arrival).
//   * Arrival: on the last leg, within 25 m of its end -> arrival card (arrived: true),
//     held 20 s, then .end.
//   * When to send: on a step change, on arrival, or once per step when the distance to
//     the maneuver drops to the prepare distance (40 m walking, 250 m driving), with
//     announce: true. Otherwise when >= 2 s have passed and the distance changed by
//     >= 10 m, and at least every 15 s.
//   * ETA: expectedTravelTime * remaining / total, rounded to minutes, minimum 1.
//
// DECISIONS BEYOND THE BRIEF (documented so hardware tests can judge them)
//   * The depart phase also ends as soon as the user reaches the second leg (otherwise a
//     first leg shorter than 30 m would hide the first turn).
//   * Off-route detection starts once the depart phase is over: rerouting a user who
//     hasn't moved would just return the same route (e.g. GPS drift indoors at start).
//     Before that, a fix more than 50 m from the route doesn't move the tracker along it.
//   * Trailing legs shorter than 1 m (MapKit's zero-length "arrive" step, if it has two
//     identical points) don't block arrival: "the last leg" means the last leg >= 1 m.
//   * No prepare announcement for the depart card itself (its maneuver is at the start).
//   * After replaceRoute, a "step change" means the instruction or maneuver changed, so a
//     reroute that yields the same next turn isn't spoken again.
//   * Distances in cards are rounded to whole metres. eta_min is omitted on the arrival
//     card and when expectedTravelTime is unknown.

import Foundation

/// A coordinate in degrees (WGS84). The app converts CLLocationCoordinate2D into this.
struct GeoPoint: Equatable {
    var lat: Double
    var lon: Double

    init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    var isValid: Bool {
        return lat.isFinite && lon.isFinite && abs(lat) <= 90 && abs(lon) <= 180
    }
}

/// Small geodesy helpers.
enum Geo {
    static let earthRadiusM: Double = 6_371_000
    static let degreesToRadians: Double = Double.pi / 180

    /// Great-circle distance in metres (haversine).
    static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let lat1: Double = a.lat * degreesToRadians
        let lat2: Double = b.lat * degreesToRadians
        let dLat: Double = (b.lat - a.lat) * degreesToRadians
        let dLon: Double = deltaLon(a.lon, b.lon) * degreesToRadians
        let s1: Double = sin(dLat / 2)
        let s2: Double = sin(dLon / 2)
        let h: Double = s1 * s1 + cos(lat1) * cos(lat2) * s2 * s2
        let hClamped: Double = min(1, max(0, h))
        let c: Double = 2 * atan2(sqrt(hClamped), sqrt(1 - hClamped))
        return earthRadiusM * c
    }

    /// b.lon - a.lon wrapped into -180...180.
    static func deltaLon(_ from: Double, _ to: Double) -> Double {
        var d: Double = to - from
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    /// The point `northM` metres north and `eastM` metres east of `p` (flat approximation,
    /// fine for the short distances used in tests and tools).
    static func offset(_ p: GeoPoint, northM: Double, eastM: Double) -> GeoPoint {
        let metresPerDegree: Double = earthRadiusM * degreesToRadians
        let dLat: Double = northM / metresPerDegree
        let cosLat: Double = max(1e-9, cos(p.lat * degreesToRadians))
        let dLon: Double = eastM / (metresPerDegree * cosLat)
        return GeoPoint(lat: p.lat + dLat, lon: p.lon + dLon)
    }

    /// Projects `p` onto the segment a-b in a local flat (equirectangular) frame centred
    /// on the segment. Returns the closest point and its fraction t (0 at a, 1 at b).
    static func project(_ p: GeoPoint, from a: GeoPoint, to b: GeoPoint) -> (point: GeoPoint, t: Double) {
        let midLat: Double = (a.lat + b.lat) / 2 * degreesToRadians
        let kx: Double = cos(midLat)
        let bx: Double = deltaLon(a.lon, b.lon) * kx
        let by: Double = b.lat - a.lat
        let px: Double = deltaLon(a.lon, p.lon) * kx
        let py: Double = p.lat - a.lat
        let len2: Double = bx * bx + by * by
        var t: Double = 0
        if len2 > 1e-18 {
            let dot: Double = px * bx + py * by
            t = min(1, max(0, dot / len2))
        }
        let lat: Double = a.lat + t * (b.lat - a.lat)
        let lon: Double = a.lon + t * deltaLon(a.lon, b.lon)
        return (point: GeoPoint(lat: lat, lon: lon), t: t)
    }
}

/// One MKRoute step as plain data (the app fills it from MKRouteStep).
struct NavStep: Equatable {
    var instruction: String
    var points: [GeoPoint]
    /// MKRouteStep.distance in metres (informational; the maths uses the polyline).
    var distance: Double

    init(instruction: String, points: [GeoPoint], distance: Double) {
        self.instruction = instruction
        self.points = points
        self.distance = distance
    }
}

/// A route step with at least two points: the instruction (the maneuver at its start),
/// its polyline and distance.
struct NavLeg: Equatable {
    let instruction: String
    let points: [GeoPoint]
    /// The step distance as given by MapKit (informational).
    let distance: Double
    /// Haversine distance along the polyline at each point (cumulative[0] == 0).
    let cumulative: [Double]

    /// nil when there are fewer than 2 valid points.
    init?(instruction: String, points: [GeoPoint], distance: Double) {
        var valid: [GeoPoint] = []
        valid.reserveCapacity(points.count)
        for p in points where p.isValid {
            valid.append(p)
        }
        guard valid.count >= 2 else { return nil }
        self.instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        self.points = valid
        self.distance = distance
        var cum: [Double] = [0]
        cum.reserveCapacity(valid.count)
        var total: Double = 0
        var k = 1
        while k < valid.count {
            total += Geo.distance(valid[k - 1], valid[k])
            cum.append(total)
            k += 1
        }
        self.cumulative = cum
    }

    /// Polyline length in metres.
    var length: Double { return cumulative[cumulative.count - 1] }
    var start: GeoPoint { return points[0] }
    var end: GeoPoint { return points[points.count - 1] }

    /// Legs from route steps: every step with 2 or more points, in order.
    static func legs(from steps: [NavStep]) -> [NavLeg] {
        var out: [NavLeg] = []
        for s in steps {
            if let leg = NavLeg(instruction: s.instruction, points: s.points, distance: s.distance) {
                out.append(leg)
            }
        }
        return out
    }

    /// Distance from `p` to this leg and the along-leg position of the closest point.
    func match(_ p: GeoPoint) -> (distance: Double, along: Double) {
        var best: Double = Double.infinity
        var bestAlong: Double = 0
        var k = 0
        while k + 1 < points.count {
            let a: GeoPoint = points[k]
            let b: GeoPoint = points[k + 1]
            let proj = Geo.project(p, from: a, to: b)
            let d: Double = Geo.distance(p, proj.point)
            if d < best {
                best = d
                let segment: Double = cumulative[k + 1] - cumulative[k]
                bestAlong = cumulative[k] + proj.t * segment
            }
            k += 1
        }
        return (distance: best, along: bestAlong)
    }
}

/// Walking or driving: sets the prepare distance for the spoken "coming up" announcement.
enum NavTransport: String {
    case walking
    case driving

    /// 40 m walking, 250 m driving.
    var prepareDistance: Double {
        switch self {
        case .walking: return 40
        case .driving: return 250
        }
    }
}

/// Everything in one `nav` message. `message()` builds it.
struct NavCard: Equatable {
    var instruction: String
    var maneuver: Maneuver
    /// Metres to the next maneuver (whole metres).
    var distanceM: Double
    var street: String?
    /// 1-based; 1 is the depart step, stepsTotal the arrival.
    var step: Int
    var stepsTotal: Int
    var etaMin: Int?
    var remainingM: Double?
    var destination: String?
    var arrived: Bool
    /// true: Glass speaks the instruction now.
    var announce: Bool

    /// The `nav` frame for GlassLink.send.
    func message() -> GBObject {
        return Msg.nav(instruction: instruction, maneuver: maneuver, distanceM: distanceM,
                       street: street, step: step, stepsTotal: stepsTotal, etaMin: etaMin,
                       remainingM: remainingM, destination: destination,
                       arrived: arrived, announce: announce)
    }
}

/// What NavigationService should do after feeding the tracker.
enum NavAction: Equatable {
    /// Send `card.message()` to Glass (and show it on the phone).
    case send(NavCard)
    /// Ask MapKit for a new route from this point to the same destination.
    case reroute(from: GeoPoint)
    /// Guidance is over: send `nav_end` and drop the tracker.
    case end
}

/// Tracks progress along a route and decides what to send to Glass. Not thread-safe:
/// use it from the main thread (NavigationService).
final class NavTracker {
    // Tunables, all from the build brief.
    static let lookAheadLegs: Int = 2
    static let currentLegBiasM: Double = 1
    static let offRouteDistanceM: Double = 50
    static let offRouteFixes: Int = 3
    static let rerouteIntervalS: TimeInterval = 10
    static let arrivalDistanceM: Double = 25
    static let arrivalHoldS: TimeInterval = 20
    static let departDistanceM: Double = 30
    static let minSendIntervalS: TimeInterval = 2
    static let minDistanceChangeM: Double = 10
    static let maxSendIntervalS: TimeInterval = 15
    /// Legs shorter than this at the end of the route don't count as "the last leg".
    static let trivialLegM: Double = 1

    let transport: NavTransport
    let destinationName: String?

    private(set) var legs: [NavLeg]
    private(set) var expectedTravelTime: TimeInterval?
    /// Sum of the leg polyline lengths (metres).
    private(set) var totalLength: Double = 0
    /// Index into `legs` of the leg the user is on.
    private(set) var currentLeg: Int = 0
    /// Metres along the current leg.
    private(set) var alongLeg: Double = 0
    private(set) var departed: Bool
    private(set) var startPoint: GeoPoint?
    /// Consecutive fixes more than 50 m from the route.
    private(set) var offRouteCount: Int = 0
    private(set) var lastRerouteRequest: TimeInterval?
    private(set) var arrivedAt: TimeInterval?
    private(set) var ended: Bool = false
    /// The most recent card computed (announce false). Drives the on-phone panel.
    private(set) var lastCard: NavCard?
    private(set) var lastSentCard: NavCard?
    private(set) var lastSentTime: TimeInterval?
    /// Increases on every replaceRoute.
    private(set) var routeGeneration: Int = 0

    private var lastSentGeneration: Int = -1
    private var preparedKey: String?
    private var effectiveLastLeg: Int = 0

    /// - Parameters:
    ///   - legs: from `NavLeg.legs(from:)`. An empty route makes a tracker that does nothing.
    ///   - expectedTravelTime: MKRoute.expectedTravelTime in seconds (nil: no ETA).
    ///   - departed: true to skip the depart step.
    init(legs: [NavLeg], transport: NavTransport, destinationName: String?,
         expectedTravelTime: TimeInterval?, departed: Bool = false) {
        self.legs = legs
        self.transport = transport
        self.destinationName = NavTracker.cleanName(destinationName)
        self.expectedTravelTime = expectedTravelTime
        self.departed = departed
        recomputeRouteTotals()
    }

    convenience init(steps: [NavStep], transport: NavTransport, destinationName: String?,
                     expectedTravelTime: TimeInterval?, departed: Bool = false) {
        self.init(legs: NavLeg.legs(from: steps), transport: transport,
                  destinationName: destinationName, expectedTravelTime: expectedTravelTime,
                  departed: departed)
    }

    var isActive: Bool { return !ended && !legs.isEmpty }
    var hasArrived: Bool { return arrivedAt != nil }
    var isOffRoute: Bool { return offRouteCount >= NavTracker.offRouteFixes }
    /// legs + 1 (the depart step plus one per following maneuver, the last being arrival).
    var stepsTotal: Int { return legs.count + 1 }

    /// Metres left on the current leg.
    var remainingOnLeg: Double {
        guard currentLeg < legs.count else { return 0 }
        let left: Double = legs[currentLeg].length - alongLeg
        return max(0, left)
    }

    /// Metres left to the destination along the route.
    var remainingDistance: Double {
        if legs.isEmpty || arrivedAt != nil { return 0 }
        var total: Double = remainingOnLeg
        var k: Int = currentLeg + 1
        while k < legs.count {
            total += legs[k].length
            k += 1
        }
        return total
    }

    /// expectedTravelTime * remaining / total in whole minutes, at least 1. nil without an
    /// expected travel time or route length.
    var etaMinutes: Int? {
        return eta(forRemaining: remainingDistance)
    }

    // MARK: Driving the tracker

    /// Call once when guidance starts: returns the first card (the depart step, announced).
    /// Pass the phone's current position if known: it becomes the point the user must move
    /// 30 m away from to leave the depart step (otherwise the first fix is used).
    func start(now: TimeInterval, at position: GeoPoint? = nil) -> [NavAction] {
        if ended || legs.isEmpty || arrivedAt != nil { return [] }
        if let p = position, p.isValid {
            if startPoint == nil {
                startPoint = p
            }
            return update(fix: p, now: now)
        }
        return decideSend(buildCard(), now: now)
    }

    /// Feed every location fix.
    func update(fix: GeoPoint, now: TimeInterval) -> [NavAction] {
        if ended || legs.isEmpty { return [] }
        if arrivedAt != nil { return tick(now: now) }
        if !fix.isValid { return [] }
        if startPoint == nil {
            startPoint = fix
        }

        // Match against the current leg and up to 2 ahead, never backwards.
        let lastCandidate: Int = min(currentLeg + NavTracker.lookAheadLegs, legs.count - 1)
        var bestLeg: Int = currentLeg
        var bestScore: Double = Double.infinity
        var bestAlong: Double = 0
        var nearest: Double = Double.infinity
        var j: Int = currentLeg
        while j <= lastCandidate {
            let m = legs[j].match(fix)
            if m.distance < nearest {
                nearest = m.distance
            }
            var score: Double = m.distance
            if j == currentLeg {
                score -= NavTracker.currentLegBiasM
            }
            if score < bestScore {
                bestScore = score
                bestLeg = j
                bestAlong = m.along
            }
            j += 1
        }

        let farFromRoute: Bool = nearest > NavTracker.offRouteDistanceM
        if departed && farFromRoute {
            offRouteCount += 1
            var actions: [NavAction] = []
            if offRouteCount >= NavTracker.offRouteFixes && rerouteAllowed(now: now) {
                lastRerouteRequest = now
                actions.append(.reroute(from: fix))
            }
            actions.append(contentsOf: keepAlive(now: now))
            return actions
        }
        offRouteCount = 0
        // Before moving off, a fix far from the route (e.g. GPS indoors) doesn't move the
        // tracker along the route; it only counts toward the 30 m depart distance.
        if !farFromRoute {
            currentLeg = bestLeg
            alongLeg = bestAlong
        }

        if !departed {
            var moved: Double = 0
            if let s = startPoint {
                moved = Geo.distance(fix, s)
            }
            if moved >= NavTracker.departDistanceM || currentLeg > 0 {
                departed = true
            }
        }

        if currentLeg >= effectiveLastLeg {
            let destinationPoint: GeoPoint = legs[legs.count - 1].end
            let toEnd: Double = Geo.distance(fix, destinationPoint)
            if toEnd <= NavTracker.arrivalDistanceM {
                return arrive(now: now)
            }
        }
        return decideSend(buildCard(), now: now)
    }

    /// Call every few seconds while guidance is active: re-sends the card at least every
    /// 15 s and ends guidance 20 s after arrival.
    func tick(now: TimeInterval) -> [NavAction] {
        if ended { return [] }
        if let arrived = arrivedAt, now - arrived >= NavTracker.arrivalHoldS {
            ended = true
            return [.end]
        }
        return keepAlive(now: now)
    }

    /// Swap in a new route after a reroute. Keeps the depart state, the send history and
    /// the reroute rate limit. Returns the card for the new route (announced only if the
    /// next maneuver changed). An empty route is ignored.
    func replaceRoute(legs newLegs: [NavLeg], expectedTravelTime newTime: TimeInterval?,
                      now: TimeInterval) -> [NavAction] {
        if ended || newLegs.isEmpty || arrivedAt != nil { return [] }
        legs = newLegs
        expectedTravelTime = newTime
        currentLeg = 0
        alongLeg = 0
        offRouteCount = 0
        routeGeneration += 1
        recomputeRouteTotals()
        return decideSend(buildCard(), now: now)
    }

    func replaceRoute(steps: [NavStep], expectedTravelTime newTime: TimeInterval?,
                      now: TimeInterval) -> [NavAction] {
        return replaceRoute(legs: NavLeg.legs(from: steps), expectedTravelTime: newTime, now: now)
    }

    /// The card to re-send when Glass reconnects: the latest state, never announced.
    /// nil before the first card and after guidance ended.
    func currentCard() -> NavCard? {
        if ended { return nil }
        guard var card = lastCard else { return nil }
        card.announce = false
        return card
    }

    /// The user ended guidance. The app sends `nav_end` itself.
    func stop() {
        ended = true
    }

    // MARK: Internals

    private func recomputeRouteTotals() {
        var total: Double = 0
        var lastReal: Int = -1
        var k = 0
        while k < legs.count {
            let len: Double = legs[k].length
            total += len
            if len >= NavTracker.trivialLegM {
                lastReal = k
            }
            k += 1
        }
        totalLength = total
        if lastReal >= 0 {
            effectiveLastLeg = lastReal
        } else {
            effectiveLastLeg = max(0, legs.count - 1)
        }
    }

    private func rerouteAllowed(now: TimeInterval) -> Bool {
        guard let last = lastRerouteRequest else { return true }
        return now - last >= NavTracker.rerouteIntervalS
    }

    private func eta(forRemaining remaining: Double) -> Int? {
        guard let travel = expectedTravelTime, travel > 0 else { return nil }
        let total: Double = totalLength
        guard total > 0 else { return nil }
        var fraction: Double = remaining / total
        fraction = min(1, max(0, fraction))
        let seconds: Double = travel * fraction
        let minutes: Double = (seconds / 60.0).rounded()
        let whole: Int = Int(minutes)
        return max(1, whole)
    }

    private static func cleanName(_ name: String?) -> String? {
        guard let n = name else { return nil }
        let t: String = n.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        return t
    }

    /// The street after " onto " in an instruction, if any.
    static func street(from instruction: String) -> String? {
        guard let r = instruction.range(of: " onto ", options: .caseInsensitive) else { return nil }
        var s: String = String(instruction[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".") {
            s.removeLast()
        }
        if s.isEmpty { return nil }
        return s
    }

    private func departText() -> String {
        if let d = destinationName {
            return "Head to " + d
        }
        return "Start the route"
    }

    private func arriveText() -> String {
        if let d = destinationName {
            return "Arrive at " + d
        }
        return "Arrive at your destination"
    }

    private func arrivedText() -> String {
        if let d = destinationName {
            return "You have arrived at " + d
        }
        return "You have arrived"
    }

    private static func roundedMetres(_ m: Double) -> Double {
        guard m.isFinite else { return 0 }
        return max(0, m).rounded()
    }

    /// The card for the current position (announce false; decideSend sets it).
    private func buildCard() -> NavCard {
        let n: Int = legs.count
        let distance: Double = NavTracker.roundedMetres(remainingOnLeg)
        let remaining: Double = remainingDistance
        let etaMin: Int? = eta(forRemaining: remaining)
        let remainingRounded: Double = NavTracker.roundedMetres(remaining)

        if !departed {
            let first: String = legs[0].instruction
            var text: String = first
            if text.isEmpty {
                text = departText()
            }
            let maneuver: Maneuver = Maneuver.classify(first, isFirstStep: true)
            return NavCard(instruction: text, maneuver: maneuver, distanceM: distance,
                           street: NavTracker.street(from: first), step: 1, stepsTotal: n + 1,
                           etaMin: etaMin, remainingM: remainingRounded,
                           destination: destinationName, arrived: false, announce: false)
        }

        let nextIndex: Int = currentLeg + 1
        if nextIndex < n {
            let next: String = legs[nextIndex].instruction
            var text: String = next
            if text.isEmpty {
                text = "Continue"
            }
            let maneuver: Maneuver = Maneuver.classify(next, isFirstStep: false)
            return NavCard(instruction: text, maneuver: maneuver, distanceM: distance,
                           street: NavTracker.street(from: next), step: currentLeg + 2,
                           stepsTotal: n + 1, etaMin: etaMin, remainingM: remainingRounded,
                           destination: destinationName, arrived: false, announce: false)
        }
        return NavCard(instruction: arriveText(), maneuver: .arrive, distanceM: distance,
                       street: nil, step: n + 1, stepsTotal: n + 1, etaMin: etaMin,
                       remainingM: remainingRounded, destination: destinationName,
                       arrived: false, announce: false)
    }

    private func arrive(now: TimeInterval) -> [NavAction] {
        arrivedAt = now
        let n: Int = legs.count
        var card = NavCard(instruction: arrivedText(), maneuver: .arrive, distanceM: 0,
                           street: nil, step: n + 1, stepsTotal: n + 1, etaMin: nil,
                           remainingM: 0, destination: destinationName, arrived: true,
                           announce: false)
        lastCard = card
        card.announce = true
        recordSent(card, now: now)
        return [.send(card)]
    }

    private func stepKey(generation: Int, step: Int) -> String {
        return String(generation) + ":" + String(step)
    }

    /// Applies the "when to send" rules to a freshly computed card.
    private func decideSend(_ card: NavCard, now: TimeInterval) -> [NavAction] {
        lastCard = card
        let key: String = stepKey(generation: routeGeneration, step: card.step)
        let prepare: Double = transport.prepareDistance
        // The depart card has no "coming up" announcement: its maneuver is at the start.
        let canPrepare: Bool = departed
        let withinPrepare: Bool = canPrepare && card.distanceM <= prepare

        var send: Bool = false
        var announce: Bool = false

        if let last = lastSentCard, let lastTime = lastSentTime {
            let stepChanged: Bool
            if lastSentGeneration == routeGeneration {
                stepChanged = last.step != card.step
            } else {
                stepChanged = last.instruction != card.instruction || last.maneuver != card.maneuver
                if !stepChanged {
                    // Same next maneuver on the new route: carry the prepare state over.
                    let lastKey: String = stepKey(generation: lastSentGeneration, step: last.step)
                    if preparedKey == lastKey {
                        preparedKey = key
                    }
                }
            }
            if stepChanged {
                send = true
                announce = true
                preparedKey = withinPrepare ? key : nil
            } else if withinPrepare && preparedKey != key {
                send = true
                announce = true
                preparedKey = key
            } else {
                let elapsed: TimeInterval = now - lastTime
                let change: Double = abs(card.distanceM - last.distanceM)
                if elapsed >= NavTracker.minSendIntervalS && change >= NavTracker.minDistanceChangeM {
                    send = true
                } else if elapsed >= NavTracker.maxSendIntervalS {
                    send = true
                }
            }
        } else {
            send = true
            announce = true
            preparedKey = withinPrepare ? key : nil
        }

        if !send { return [] }
        var out: NavCard = card
        out.announce = announce
        recordSent(out, now: now)
        return [.send(out)]
    }

    /// Re-sends the latest card (not announced) when 15 s have passed since the last send.
    private func keepAlive(now: TimeInterval) -> [NavAction] {
        guard let lastTime = lastSentTime, var card = lastCard else { return [] }
        if now - lastTime < NavTracker.maxSendIntervalS { return [] }
        card.announce = false
        recordSent(card, now: now)
        return [.send(card)]
    }

    private func recordSent(_ card: NavCard, now: TimeInterval) {
        lastSentCard = card
        lastSentTime = now
        lastSentGeneration = routeGeneration
    }
}
