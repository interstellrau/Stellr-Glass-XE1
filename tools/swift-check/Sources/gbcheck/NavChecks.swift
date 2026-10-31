// NavChecks.swift - part 3: NavTracker on synthetic routes.

import Foundation

private func sends(_ actions: [NavAction]) -> [NavCard] {
    var out: [NavCard] = []
    for a in actions {
        if case .send(let card) = a { out.append(card) }
    }
    return out
}

private func reroutes(_ actions: [NavAction]) -> Int {
    var n = 0
    for a in actions {
        if case .reroute = a { n += 1 }
    }
    return n
}

private func ends(_ actions: [NavAction]) -> Int {
    var n = 0
    for a in actions where a == .end {
        n += 1
    }
    return n
}

/// Expects exactly one send and returns it.
private func oneSend(_ actions: [NavAction], _ name: String, _ c: Checker) -> NavCard? {
    let s: [NavCard] = sends(actions)
    let ok: Bool = c.check(s.count == 1 && actions.count == 1, name + ": exactly one send", "got \(actions)")
    return ok ? s[0] : nil
}

private func describe(_ card: NavCard) -> String {
    return "step \(card.step)/\(card.stepsTotal) \(card.maneuver.rawValue) \(card.distanceM) m '\(card.instruction)' announce=\(card.announce)"
}

func runNav() -> Int32 {
    let c = Checker(part: "part 3 (NavTracker on a synthetic route)")

    // Route near Adelaide: 300 m north, 200 m east, 150 m north (with a midpoint).
    let p0 = GeoPoint(lat: -34.9285, lon: 138.6007)
    let p1: GeoPoint = Geo.offset(p0, northM: 300, eastM: 0)
    let p2: GeoPoint = Geo.offset(p1, northM: 0, eastM: 200)
    let p2m: GeoPoint = Geo.offset(p2, northM: 75, eastM: 0)
    let p3: GeoPoint = Geo.offset(p2, northM: 150, eastM: 0)
    func onLeg0(_ d: Double) -> GeoPoint { return Geo.offset(p0, northM: d, eastM: 0) }
    func onLeg1(_ e: Double) -> GeoPoint { return Geo.offset(p1, northM: 0, eastM: e) }
    func onLeg2(_ d: Double) -> GeoPoint { return Geo.offset(p2, northM: d, eastM: 0) }
    let offRoute: GeoPoint = Geo.offset(onLeg1(50), northM: -80, eastM: 0)

    let steps: [NavStep] = [
        NavStep(instruction: "", points: [p0], distance: 0),
        NavStep(instruction: "Proceed north on Test Street", points: [p0, p1], distance: 300),
        NavStep(instruction: "Turn right onto Second Avenue", points: [p1, p2], distance: 200),
        NavStep(instruction: "Turn left onto Third Street", points: [p2, p2m, p3], distance: 150),
        NavStep(instruction: "Arrive at the destination", points: [p3], distance: 0),
    ]

    c.begin("geo")
    c.near(Geo.distance(p0, p1), 300, 0.01, "haversine 300 m north")
    c.near(Geo.distance(p1, p2), 200, 0.01, "haversine 200 m east")
    let mid: GeoPoint = Geo.offset(Geo.offset(p1, northM: 0, eastM: 100), northM: 10, eastM: 0)
    let proj = Geo.project(mid, from: p1, to: p2)
    c.near(proj.t, 0.5, 0.001, "projection t at the middle")
    c.near(Geo.distance(mid, proj.point), 10, 0.01, "projection distance 10 m")
    let before = Geo.project(Geo.offset(p1, northM: 0, eastM: -30), from: p1, to: p2)
    c.near(before.t, 0, 1e-9, "projection clamps to the segment start")
    c.near(Geo.distance(p0, Geo.offset(p0, northM: 0, eastM: 1000)), 1000, 0.05, "haversine 1 km east")
    c.near(Geo.deltaLon(179.5, -179.5), 1, 1e-9, "longitude wraps across 180")

    c.begin("legs")
    let legs: [NavLeg] = NavLeg.legs(from: steps)
    c.equal(legs.count, 3, "steps with fewer than 2 points are dropped")
    c.equal(legs.map { $0.instruction }, ["Proceed north on Test Street", "Turn right onto Second Avenue", "Turn left onto Third Street"], "leg instructions")
    c.near(legs[2].length, 150, 0.01, "multi-segment leg length")
    let nanStep = NavStep(instruction: "x", points: [p0, GeoPoint(lat: Double.nan, lon: 1)], distance: 1)
    c.equal(NavLeg.legs(from: [nanStep]).count, 0, "invalid coordinates are dropped")

    // ---------------------------------------------------------------- walking
    c.begin("walk")
    let t = NavTracker(steps: steps, transport: .walking, destinationName: "Test Destination",
                       expectedTravelTime: 600)
    c.equal(t.stepsTotal, 4, "steps_total = legs + 1")
    c.near(t.totalLength, 650, 0.05, "total length")

    // 1. Start: the depart card, announced.
    if let card = oneSend(t.start(now: 0, at: p0), "start", c) {
        c.equal(card.step, 1, "depart step is 1")
        c.equal(card.stepsTotal, 4, "depart steps_total")
        c.equal(card.maneuver, .depart, "depart maneuver")
        c.equal(card.instruction, "Proceed north on Test Street", "depart instruction")
        c.equal(card.distanceM, 300, "depart distance = first leg")
        c.equal(card.announce, true, "depart announced")
        c.equal(card.remainingM ?? -1, 650, "remaining 650")
        c.equal(card.etaMin ?? -1, 10, "eta 600 s * 650/650 = 10 min")
        c.equal(card.destination ?? "", "Test Destination", "destination")
        c.equal(card.arrived, false, "not arrived")
        let msg: GBObject = card.message()
        c.equal(msg.type ?? "", "nav", "message type nav")
        c.equal(msg.string("maneuver") ?? "", "depart", "message maneuver")
        c.check(msg["distance_m"] == .double(300), "message distance_m", short(msg["distance_m"]))
        c.check(msg["step"] == .int(1) && msg["steps_total"] == .int(4), "message step ints")
        c.check(msg["eta_min"] == .int(10), "message eta_min int")
        c.check(msg["announce"] == .bool(true) && msg["arrived"] == .bool(false), "message booleans")
        c.check(msg["street"] == nil, "no street without 'onto'")
    }
    // 2. 5 m, 1 s later: nothing (under 2 s and under 10 m).
    c.equal(t.update(fix: onLeg0(5), now: 1).count, 0, "5 m after 1 s: no send")
    c.equal(t.departed, false, "not departed at 5 m")
    c.equal(t.lastCard?.distanceM ?? -1, 295, "card tracks 295 m")
    // 3. 20 m at 3 s: distance changed 20 m, 3 s since the last send.
    if let card = oneSend(t.update(fix: onLeg0(20), now: 3), "20 m at 3 s", c) {
        c.equal(card.step, 1, "still the depart step under 30 m")
        c.equal(card.distanceM, 280, "distance 280")
        c.equal(card.announce, false, "distance update not announced")
        c.equal(card.etaMin ?? -1, 10, "eta 9.69 rounds to 10")
    }
    // 4. 35 m: moved 30 m from the start -> next maneuver, announced.
    if let card = oneSend(t.update(fix: onLeg0(35), now: 5), "35 m departs", c) {
        c.equal(card.step, 2, "step 2 after moving off")
        c.equal(card.maneuver, .right, "next maneuver right")
        c.equal(card.instruction, "Turn right onto Second Avenue", "next instruction")
        c.equal(card.street ?? "", "Second Avenue", "street from 'onto'")
        c.equal(card.distanceM, 265, "distance left on the current leg")
        c.equal(card.announce, true, "step change announced")
        c.equal(card.etaMin ?? -1, 9, "eta 9.46 rounds to 9")
        c.equal(card.remainingM ?? -1, 615, "remaining 615")
    }
    c.equal(t.departed, true, "departed at 35 m")
    // 5. 100 m at 7 s: exactly 2 s later, 65 m change.
    if let card = oneSend(t.update(fix: onLeg0(100), now: 7), "100 m at 7 s", c) {
        c.equal(card.distanceM, 200, "distance 200")
        c.equal(card.announce, false, "not announced")
    }
    // 6. 105 m at 8 s: under 2 s.
    c.equal(t.update(fix: onLeg0(105), now: 8).count, 0, "1 s later: no send")
    // 7-8. No fixes: re-send at least every 15 s.
    c.equal(t.tick(now: 21).count, 0, "tick 14 s after a send: nothing")
    if let card = oneSend(t.tick(now: 22.5), "tick 15.5 s after a send", c) {
        c.equal(card.distanceM, 195, "re-sends the latest card (195 m)")
        c.equal(card.announce, false, "re-send not announced")
    }
    // 9. Prepare distance (40 m walking): announced once.
    if let card = oneSend(t.update(fix: onLeg0(262), now: 24), "38 m to the turn", c) {
        c.equal(card.distanceM, 38, "distance 38")
        c.equal(card.announce, true, "prepare distance announced")
        c.equal(card.step, 2, "same step")
    }
    // 10. 30 m, 1 s later: nothing (under 2 s, prepare already spoken).
    c.equal(t.update(fix: onLeg0(270), now: 25).count, 0, "30 m after 1 s: no send")
    // 11. 28 m at 27 s: 10 m change since the last send, not announced again.
    if let card = oneSend(t.update(fix: onLeg0(272), now: 27), "28 m", c) {
        c.equal(card.distanceM, 28, "distance 28")
        c.equal(card.announce, false, "prepare announcement only once per step")
    }
    // 12.
    if let card = oneSend(t.update(fix: onLeg0(299), now: 29), "1 m", c) {
        c.equal(card.distanceM, 1, "distance 1")
        c.equal(card.announce, false, "not announced")
    }
    // 13. Round the corner onto leg 2 of 3.
    if let card = oneSend(t.update(fix: onLeg1(20), now: 31), "onto the second leg", c) {
        c.equal(card.step, 3, "step 3")
        c.equal(card.maneuver, .left, "next maneuver left")
        c.equal(card.instruction, "Turn left onto Third Street", "instruction")
        c.equal(card.distanceM, 180, "distance 180")
        c.equal(card.announce, true, "step change announced")
    }
    c.equal(t.currentLeg, 1, "current leg 1")
    // 14. A fix back on the previous leg never moves the tracker backwards.
    if let card = oneSend(t.update(fix: onLeg0(290), now: 33), "fix on an earlier leg", c) {
        c.equal(card.step, 3, "still step 3")
        c.equal(card.distanceM, 200, "projected to the start of the current leg")
    }
    c.equal(t.currentLeg, 1, "never backwards")

    // 15. Off route: > 50 m for 3 fixes in a row -> reroute, at most once per 10 s.
    c.begin("off route")
    let along: Double = t.alongLeg
    c.equal(t.update(fix: offRoute, now: 40).count, 0, "1st off-route fix: nothing")
    c.equal(t.offRouteCount, 1, "count 1")
    c.equal(t.update(fix: offRoute, now: 41).count, 0, "2nd off-route fix: nothing")
    let third: [NavAction] = t.update(fix: offRoute, now: 42)
    c.equal(third, [.reroute(from: offRoute)], "3rd off-route fix: reroute from the fix")
    c.equal(t.isOffRoute, true, "isOffRoute")
    c.equal(reroutes(t.update(fix: offRoute, now: 43)), 0, "4th fix 1 s later: rate-limited")
    let fifth: [NavAction] = t.update(fix: offRoute, now: 50)
    c.equal(reroutes(fifth), 0, "8 s after the reroute: still rate-limited")
    c.equal(sends(fifth).count, 1, "15 s keep-alive re-send while off route")
    c.equal(sends(fifth).first?.announce ?? true, false, "keep-alive not announced")
    c.equal(sends(fifth).first?.distanceM ?? -1, 200, "keep-alive repeats the last on-route card")
    c.equal(t.update(fix: offRoute, now: 52), [.reroute(from: offRoute)], "10 s after the reroute: reroute again")
    c.equal(t.currentLeg, 1, "off-route fixes don't move the leg")
    c.near(t.alongLeg, along, 1e-9, "off-route fixes don't move along the leg")
    // 16. Back on route.
    if let card = oneSend(t.update(fix: onLeg1(100), now: 54), "back on route", c) {
        c.equal(card.distanceM, 100, "distance 100")
        c.equal(card.step, 3, "step 3")
        c.equal(card.announce, false, "not announced")
    }
    c.equal(t.offRouteCount, 0, "count reset on an on-route fix")
    if let current = t.currentCard() {
        c.equal(current.announce, false, "currentCard (reconnect) is never announced")
        c.equal(current.distanceM, 100, "currentCard has the latest state")
        c.equal(current.step, 3, "currentCard step")
    } else {
        c.check(false, "currentCard available")
    }
    // 17. The 3-in-a-row count restarts after an on-route fix.
    c.equal(reroutes(t.update(fix: offRoute, now: 55)), 0, "off (1)")
    c.equal(t.update(fix: onLeg1(105), now: 56).count, 0, "on route again, 5 m change: no send")
    c.equal(reroutes(t.update(fix: offRoute, now: 70)), 0, "off (1) 18 s after the last reroute: no reroute yet")
    c.equal(reroutes(t.update(fix: offRoute, now: 71)), 0, "off (2): no reroute")
    c.equal(reroutes(t.update(fix: offRoute, now: 72)), 1, "off (3): reroute")

    // 19. Last leg.
    c.begin("arrival")
    if let card = oneSend(t.update(fix: onLeg2(10), now: 80), "onto the last leg", c) {
        c.equal(card.step, 4, "step 4 of 4")
        c.equal(card.maneuver, .arrive, "next maneuver arrive")
        c.equal(card.instruction, "Arrive at Test Destination", "arrive instruction")
        c.equal(card.distanceM, 140, "distance 140")
        c.equal(card.announce, true, "announced")
        c.equal(card.etaMin ?? -1, 2, "eta 2.15 rounds to 2")
    }
    // 20. 30 m to go: prepare announcement; ETA minimum 1.
    if let card = oneSend(t.update(fix: onLeg2(120), now: 82), "30 m to go", c) {
        c.equal(card.distanceM, 30, "distance 30")
        c.equal(card.announce, true, "prepare announced")
        c.equal(card.etaMin ?? -1, 1, "eta 0.46 min is shown as 1 (minimum)")
        c.equal(card.arrived, false, "not yet arrived (30 m > 25 m)")
    }
    // 21. Within 25 m of the end of the last leg: arrival.
    if let card = oneSend(t.update(fix: onLeg2(130), now: 84), "within 25 m", c) {
        c.equal(card.arrived, true, "arrived")
        c.equal(card.announce, true, "arrival announced")
        c.equal(card.maneuver, .arrive, "arrive maneuver")
        c.equal(card.step, 4, "step = steps_total")
        c.equal(card.distanceM, 0, "distance 0")
        c.equal(card.remainingM ?? -1, 0, "remaining 0")
        c.check(card.etaMin == nil, "no eta on the arrival card")
        c.equal(card.instruction, "You have arrived at Test Destination", "arrival text")
        c.check(card.message()["arrived"] == .bool(true), "message arrived true")
    }
    c.equal(t.hasArrived, true, "hasArrived")
    // 22. Held for 20 s, then end.
    c.equal(t.update(fix: onLeg2(140), now: 86).count, 0, "fixes during the hold: nothing")
    if let card = oneSend(t.tick(now: 99), "15 s into the hold", c) {
        c.equal(card.arrived, true, "keep-alive repeats the arrival card")
        c.equal(card.announce, false, "not announced")
    }
    c.equal(t.tick(now: 103.9).count, 0, "19.9 s after arrival: still held")
    c.equal(t.tick(now: 104), [.end], "20 s after arrival: end")
    c.equal(t.ended, true, "ended")
    c.equal(t.update(fix: onLeg2(150), now: 105).count, 0, "nothing after the end")
    c.check(t.currentCard() == nil, "no card to re-send after the end")
    c.equal(ends(t.tick(now: 200)), 0, "end is reported once")

    // ---------------------------------------------------------------- leg bias
    c.begin("matching")
    let biasTracker = NavTracker(steps: steps, transport: .walking, destinationName: nil, expectedTravelTime: 600)
    _ = biasTracker.start(now: 0, at: p0)
    _ = biasTracker.update(fix: onLeg0(100), now: 2)
    // 0.78 m from leg 1's start corner, 0.6 m from leg 2: under the 1 m bias, so stay.
    let nearCorner: GeoPoint = Geo.offset(p1, northM: 0.6, eastM: 0.5)
    _ = biasTracker.update(fix: nearCorner, now: 4)
    c.equal(biasTracker.currentLeg, 0, "1 m bias keeps the current leg when the next is < 1 m closer")
    let pastCorner: GeoPoint = Geo.offset(p1, northM: 0.5, eastM: 3)
    _ = biasTracker.update(fix: pastCorner, now: 6)
    c.equal(biasTracker.currentLeg, 1, "next leg wins when it is more than 1 m closer")

    // Look-ahead is limited to 2 legs.
    // Corners of a staircase: north, east, north, east, north (100 m each).
    var corners: [GeoPoint] = [GeoPoint(lat: -34.91, lon: 138.61)]
    for k in 0..<5 {
        let prev: GeoPoint = corners[corners.count - 1]
        if k % 2 == 0 {
            corners.append(Geo.offset(prev, northM: 100, eastM: 0))
        } else {
            corners.append(Geo.offset(prev, northM: 0, eastM: 100))
        }
    }
    var laSteps: [NavStep] = []
    for k in 0..<5 {
        laSteps.append(NavStep(instruction: "Leg \(k)", points: [corners[k], corners[k + 1]], distance: 100))
    }
    let look = NavTracker(steps: laSteps, transport: .walking, destinationName: nil, expectedTravelTime: 300)
    _ = look.start(now: 0, at: corners[0])
    _ = look.update(fix: Geo.offset(corners[0], northM: 40, eastM: 0), now: 2)
    c.equal(look.currentLeg, 0, "on leg 0")
    let onLeg3: GeoPoint = Geo.offset(corners[3], northM: 0, eastM: 80)
    _ = look.update(fix: onLeg3, now: 4)
    c.equal(look.currentLeg, 0, "a fix on leg 3 (3 ahead) is not matched")
    c.equal(look.offRouteCount, 1, "...and counts as off route")
    _ = look.update(fix: Geo.offset(corners[2], northM: 50, eastM: 0), now: 6)
    c.equal(look.currentLeg, 2, "a fix on leg 2 (2 ahead) is matched")
    _ = look.update(fix: onLeg3, now: 8)
    c.equal(look.currentLeg, 3, "leg 3 is matched once it is within 2 legs")

    // ---------------------------------------------------------------- driving
    c.begin("drive")
    let q0 = GeoPoint(lat: -34.9, lon: 138.6)
    let q1: GeoPoint = Geo.offset(q0, northM: 1000, eastM: 0)
    let q2: GeoPoint = Geo.offset(q1, northM: 0, eastM: 500)
    let driveSteps: [NavStep] = [
        NavStep(instruction: "Head north on Long Road", points: [q0, q1], distance: 1000),
        NavStep(instruction: "Turn right onto Cross Road", points: [q1, q2], distance: 500),
    ]
    c.equal(NavTransport.walking.prepareDistance, 40, "walking prepare distance")
    c.equal(NavTransport.driving.prepareDistance, 250, "driving prepare distance")
    let d = NavTracker(steps: driveSteps, transport: .driving, destinationName: nil, expectedTravelTime: nil)
    if let card = oneSend(d.start(now: 0, at: q0), "drive start", c) {
        c.equal(card.distanceM, 1000, "depart 1000 m")
        c.check(card.etaMin == nil, "no eta without expectedTravelTime")
        c.check(card.message()["eta_min"] == nil, "eta_min left out")
        c.check(card.destination == nil, "no destination name")
    }
    if let card = oneSend(d.update(fix: Geo.offset(q0, northM: 100, eastM: 0), now: 10), "drive departs", c) {
        c.equal(card.step, 2, "step 2")
        c.equal(card.distanceM, 900, "900 m")
        c.equal(card.announce, true, "announced")
    }
    if let card = oneSend(d.update(fix: Geo.offset(q0, northM: 700, eastM: 0), now: 20), "drive 300 m out", c) {
        c.equal(card.announce, false, "300 m: not the prepare distance yet")
    }
    if let card = oneSend(d.update(fix: Geo.offset(q0, northM: 760, eastM: 0), now: 25), "drive 240 m out", c) {
        c.equal(card.distanceM, 240, "240 m")
        c.equal(card.announce, true, "driving prepare distance 250 m announced")
    }
    if let card = oneSend(d.update(fix: Geo.offset(q0, northM: 770, eastM: 0), now: 27), "drive 230 m out", c) {
        c.equal(card.announce, false, "not announced twice")
    }
    if let card = oneSend(d.update(fix: Geo.offset(q1, northM: 0, eastM: 100), now: 40), "drive last leg", c) {
        c.equal(card.instruction, "Arrive at your destination", "arrive text without a name")
        c.equal(card.step, 3, "step 3 of 3")
    }

    // ---------------------------------------------------------------- short first leg
    c.begin("short first leg")
    let s0 = GeoPoint(lat: -34.95, lon: 138.55)
    let s1: GeoPoint = Geo.offset(s0, northM: 20, eastM: 0)
    let s2: GeoPoint = Geo.offset(s1, northM: 0, eastM: 200)
    let shortSteps: [NavStep] = [
        NavStep(instruction: "", points: [s0, s1], distance: 20),
        NavStep(instruction: "Turn right onto Short St", points: [s1, s2], distance: 200),
    ]
    let st = NavTracker(steps: shortSteps, transport: .walking, destinationName: "Shop", expectedTravelTime: 180)
    if let card = oneSend(st.start(now: 0), "short start", c) {
        c.equal(card.maneuver, .depart, "empty first instruction classifies as depart")
        c.equal(card.instruction, "Head to Shop", "empty first instruction gets a depart text")
    }
    if let card = oneSend(st.update(fix: Geo.offset(s1, northM: 0, eastM: 5), now: 5), "past the first turn", c) {
        c.equal(st.departed, true, "reaching leg 2 ends the depart phase before 30 m")
        c.equal(card.step, 3, "step 3 of 3")
        c.equal(card.maneuver, .arrive, "next is the arrival")
    }

    // ---------------------------------------------------------------- zero-length final step
    c.begin("zero-length final step")
    let z0 = GeoPoint(lat: -34.92, lon: 138.62)
    let z1: GeoPoint = Geo.offset(z0, northM: 100, eastM: 0)
    let z2: GeoPoint = Geo.offset(z1, northM: 0, eastM: 100)
    let zSteps: [NavStep] = [
        NavStep(instruction: "Proceed north", points: [z0, z1], distance: 100),
        NavStep(instruction: "Turn right onto A Street", points: [z1, z2], distance: 100),
        NavStep(instruction: "The destination is on your right", points: [z2, z2], distance: 0),
    ]
    let z = NavTracker(steps: zSteps, transport: .walking, destinationName: "Cafe", expectedTravelTime: 150)
    c.equal(z.stepsTotal, 4, "zero-length step with 2 points is still a leg")
    _ = z.start(now: 0)
    _ = z.update(fix: Geo.offset(z0, northM: 40, eastM: 0), now: 3)
    if let card = oneSend(z.update(fix: Geo.offset(z1, northM: 0, eastM: 10), now: 6), "on A Street", c) {
        c.equal(card.maneuver, .arrive, "'destination is' classifies as arrive")
        c.equal(card.instruction, "The destination is on your right", "MapKit arrival text used")
        c.equal(card.step, 3, "step 3 of 4")
    }
    if let card = oneSend(z.update(fix: Geo.offset(z1, northM: 0, eastM: 80), now: 9), "20 m from the end", c) {
        c.equal(card.arrived, true, "arrival on the last real leg")
        c.equal(card.step, 4, "arrival step 4 of 4")
    }

    // ---------------------------------------------------------------- reroute
    c.begin("reroute")
    let r0 = GeoPoint(lat: -34.93, lon: 138.58)
    let r1: GeoPoint = Geo.offset(r0, northM: 100, eastM: 0)
    let r2: GeoPoint = Geo.offset(r1, northM: 0, eastM: 300)
    let r3: GeoPoint = Geo.offset(r2, northM: 100, eastM: 0)
    let routeA: [NavStep] = [
        NavStep(instruction: "Proceed north", points: [r0, r1], distance: 100),
        NavStep(instruction: "Turn right onto B Street", points: [r1, r2], distance: 300),
        NavStep(instruction: "Turn left onto C Street", points: [r2, r3], distance: 100),
    ]
    let r = NavTracker(steps: routeA, transport: .walking, destinationName: "Park", expectedTravelTime: 400)
    _ = r.start(now: 0, at: r0)
    if let card = oneSend(r.update(fix: Geo.offset(r0, northM: 50, eastM: 0), now: 2), "reroute departs", c) {
        c.equal(card.instruction, "Turn right onto B Street", "next turn")
    }
    let away: GeoPoint = Geo.offset(r0, northM: 50, eastM: -100)
    _ = r.update(fix: away, now: 10)
    _ = r.update(fix: away, now: 11)
    c.equal(r.update(fix: away, now: 12), [.reroute(from: away)], "reroute requested")
    // New route from the off-route fix that leads to the same next turn.
    let routeB: [NavStep] = [
        NavStep(instruction: "Head northeast", points: [away, r1], distance: 112),
        NavStep(instruction: "Turn right onto B Street", points: [r1, r2], distance: 300),
        NavStep(instruction: "Turn left onto C Street", points: [r2, r3], distance: 100),
    ]
    let replaced: [NavAction] = r.replaceRoute(steps: routeB, expectedTravelTime: 380, now: 13)
    if let card = oneSend(replaced, "same next turn after reroute", c) {
        c.equal(card.instruction, "Turn right onto B Street", "same instruction")
        c.equal(card.announce, false, "same next turn is not spoken again")
        c.equal(card.step, 2, "step 2 of the new route")
        c.equal(card.distanceM, 112, "distance along the new first leg")
    }
    c.equal(r.routeGeneration, 1, "route generation 1")
    c.equal(r.offRouteCount, 0, "off-route count reset")
    c.equal(r.departed, true, "depart phase stays over")
    // The reroute rate limit survives replaceRoute.
    let away2: GeoPoint = Geo.offset(away, northM: -100, eastM: -100)
    _ = r.update(fix: away2, now: 14)
    _ = r.update(fix: away2, now: 15)
    c.equal(reroutes(r.update(fix: away2, now: 16)), 0, "rate limit kept across replaceRoute (4 s)")
    c.equal(reroutes(r.update(fix: away2, now: 22)), 1, "reroute again 10 s after the last request")
    let routeC: [NavStep] = [
        NavStep(instruction: "Head south", points: [away2, Geo.offset(away2, northM: -50, eastM: 0)], distance: 50),
        NavStep(instruction: "Turn left onto D Street", points: [Geo.offset(away2, northM: -50, eastM: 0), r2], distance: 400),
    ]
    if let card = oneSend(r.replaceRoute(steps: routeC, expectedTravelTime: 300, now: 23), "different next turn after reroute", c) {
        c.equal(card.instruction, "Turn left onto D Street", "new instruction")
        c.equal(card.maneuver, .left, "new maneuver")
        c.equal(card.announce, true, "a different next turn is announced")
        c.equal(card.stepsTotal, 3, "steps_total of the new route")
    }
    c.equal(r.replaceRoute(steps: [], expectedTravelTime: nil, now: 24).count, 0, "an empty route is ignored")
    c.equal(r.legs.count, 2, "legs kept after an empty replace")

    // ---------------------------------------------------------------- empty and stop
    c.begin("edge cases")
    let empty = NavTracker(steps: [NavStep(instruction: "x", points: [r0], distance: 0)], transport: .walking,
                           destinationName: nil, expectedTravelTime: 10)
    c.equal(empty.isActive, false, "no legs: inactive")
    c.equal(empty.start(now: 0).count, 0, "no legs: start sends nothing")
    c.equal(empty.update(fix: r0, now: 1).count, 0, "no legs: update does nothing")
    let stopped = NavTracker(steps: routeA, transport: .walking, destinationName: nil, expectedTravelTime: 100)
    _ = stopped.start(now: 0)
    stopped.stop()
    c.equal(stopped.ended, true, "stop ends guidance")
    c.equal(stopped.update(fix: r1, now: 1).count, 0, "nothing after stop")
    c.check(stopped.currentCard() == nil, "no card after stop")
    let pre = NavTracker(steps: routeA, transport: .walking, destinationName: nil, expectedTravelTime: 100)
    c.check(pre.currentCard() == nil, "no card before start")
    _ = pre.start(now: 0)
    c.equal(pre.currentCard()?.announce ?? true, false, "currentCard after start is not announced")
    // Off-route detection waits until the user has moved off (rerouting from the start
    // would return the same route).
    let indoor: GeoPoint = Geo.offset(r0, northM: 0, eastM: -60)
    let atStart = NavTracker(steps: routeA, transport: .walking, destinationName: nil, expectedTravelTime: 100)
    _ = atStart.start(now: 0)
    _ = atStart.update(fix: indoor, now: 1)
    _ = atStart.update(fix: indoor, now: 2)
    c.equal(reroutes(atStart.update(fix: indoor, now: 3)), 0, "no reroute before moving off")
    c.equal(atStart.departed, false, "standing still 60 m from the route: not departed")
    c.equal(atStart.alongLeg, 0, "a far fix before moving off doesn't move along the route")
    c.equal(atStart.lastCard?.distanceM ?? -1, 100, "depart card keeps the full first leg")
    // Walking 35 m while still far from the route ends the depart phase; then 3 far fixes
    // in a row ask for a reroute.
    let indoor2: GeoPoint = Geo.offset(r0, northM: 0, eastM: -95)
    _ = atStart.update(fix: indoor2, now: 5)
    c.equal(atStart.departed, true, "moving 35 m departs even far from the route")
    c.equal(reroutes(atStart.update(fix: indoor2, now: 6)), 0, "far (1)")
    c.equal(reroutes(atStart.update(fix: indoor2, now: 7)), 0, "far (2)")
    c.equal(reroutes(atStart.update(fix: indoor2, now: 8)), 1, "far (3) after departing: reroute")
    c.equal(NavTracker.street(from: "Turn left onto King William St."), "King William St", "street trims the full stop")
    c.check(NavTracker.street(from: "Continue straight") == nil, "no street without onto")

    // ---------------------------------------------------------------- coarse fixes
    // Before guidance the phone runs at 100 m accuracy: a coarse last fix must not become
    // the depart origin, and coarse fixes don't count toward the 30 m depart distance.
    c.begin("coarse fixes and the depart origin")
    c.equal(NavTracker.isUsableOrigin(accuracyM: 5, ageS: 1), true, "5 m, 1 s old: usable origin")
    c.equal(NavTracker.isUsableOrigin(accuracyM: 20, ageS: 10), true, "20 m, 10 s old: usable origin")
    c.equal(NavTracker.isUsableOrigin(accuracyM: 21, ageS: 1), false, "21 m: not an origin")
    c.equal(NavTracker.isUsableOrigin(accuracyM: 65, ageS: 0), false, "65 m Wi-Fi fix: not an origin")
    c.equal(NavTracker.isUsableOrigin(accuracyM: 5, ageS: 11), false, "11 s old: not an origin")
    c.equal(NavTracker.isUsableOrigin(accuracyM: -1, ageS: 0), false, "negative (invalid) accuracy: not an origin")
    let co = NavTracker(steps: routeA, transport: .walking, destinationName: nil, expectedTravelTime: 100)
    if let card = oneSend(co.start(now: 0), "start without an origin", c) {
        c.equal(card.step, 1, "depart card")
    }
    // The user stands at r0; the first fix is a coarse one 40 m away.
    _ = co.update(fix: Geo.offset(r0, northM: 40, eastM: 0), now: 1, accuracyM: 65)
    c.check(co.startPoint == nil, "a 65 m fix doesn't become the origin")
    c.equal(co.departed, false, "a 65 m fix doesn't depart")
    _ = co.update(fix: r0, now: 2, accuracyM: 5)
    c.check(co.startPoint == r0, "the first accurate fix becomes the origin")
    c.equal(co.departed, false, "standing still after a coarse fix: not departed")
    _ = co.update(fix: Geo.offset(r0, northM: 10, eastM: 40), now: 3, accuracyM: 45)
    c.equal(co.departed, false, "a 45 m fix 41 m from the origin doesn't depart")
    _ = co.update(fix: Geo.offset(r0, northM: 35, eastM: 0), now: 4, accuracyM: 8)
    c.equal(co.departed, true, "an accurate fix 35 m from the origin departs")
    // Poor GPS throughout: reaching the second leg still ends the depart step.
    let poor = NavTracker(steps: routeA, transport: .walking, destinationName: nil, expectedTravelTime: 100)
    _ = poor.start(now: 0)
    _ = poor.update(fix: Geo.offset(r1, northM: 0, eastM: 60), now: 5, accuracyM: 40)
    c.equal(poor.departed, true, "a coarse fix on the second leg ends the depart step")
    c.equal(poor.currentLeg, 1, "and moves the tracker onto it")

    // ---------------------------------------------------------------- nav on accept
    // PROTOCOL.md section 4 step 3: the current card while guiding, nav_end otherwise.
    c.begin("nav frame for an accepted Glass")
    c.equal(NavTracker.messageOnAccept(nil)?.type ?? "nil", "nav_end", "no tracker: nav_end")
    let acc = NavTracker(steps: routeA, transport: .walking, destinationName: "Park", expectedTravelTime: 100)
    c.check(NavTracker.messageOnAccept(acc) == nil, "guiding without a card yet: nothing")
    _ = acc.start(now: 0, at: r0)
    let onAccept: GBObject? = NavTracker.messageOnAccept(acc)
    c.equal(onAccept?.type ?? "nil", "nav", "guiding: the nav card")
    c.equal(onAccept?.bool("announce") ?? true, false, "the accept-time nav card is not announced")
    c.equal(onAccept?.string("destination") ?? "", "Park", "it is the current card")
    acc.stop()
    c.equal(NavTracker.messageOnAccept(acc)?.type ?? "nil", "nav_end", "after stop: nav_end")
    c.equal(NavTracker.messageOnAccept(empty)?.type ?? "nil", "nav_end", "a tracker with no legs: nav_end")

    if !c.failures.isEmpty {
        print("  (last walk card: \(t.lastCard.map(describe) ?? "none"))")
    }
    return c.finish()
}
