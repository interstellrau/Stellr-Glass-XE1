import Foundation
@_exported import CoreLocation
public struct MKCoordinateRegion { public init(center centerCoordinate: CLLocationCoordinate2D, latitudinalMeters: CLLocationDistance, longitudinalMeters: CLLocationDistance) {}; public init() {} }
public struct MKMapSize { public var width: Double = 0; public var height: Double = 0 }
public struct MKMapRect { public var size: MKMapSize = MKMapSize(); public func insetBy(dx: Double, dy: Double) -> MKMapRect { return self } }
open class MKMultiPoint: NSObject { open var pointCount: Int { return 0 }; open func getCoordinates(_ coords: UnsafeMutablePointer<CLLocationCoordinate2D>, range: NSRange) {} }
open class MKPolyline: MKMultiPoint { open var boundingMapRect: MKMapRect { return MKMapRect() } }
open class MKPlacemark: NSObject { public init(coordinate: CLLocationCoordinate2D) {}; open var coordinate: CLLocationCoordinate2D { return CLLocationCoordinate2D() } }
open class MKMapItem: NSObject {
    @available(*, deprecated, message: "iOS 26: Use init(location:address:)") public init(placemark: MKPlacemark) {}
    open class func forCurrentLocation() -> MKMapItem { return MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D())) }
    @available(*, deprecated, message: "iOS 26: use location") open var placemark: MKPlacemark { return MKPlacemark(coordinate: CLLocationCoordinate2D()) }
    open var name: String?
}
open class MKRoute: NSObject {
    open class Step: NSObject { open var instructions: String { return "" }; open var polyline: MKPolyline { return MKPolyline() }; open var distance: CLLocationDistance { return 0 } }
    open var steps: [MKRoute.Step] { return [] }
    open var polyline: MKPolyline { return MKPolyline() }
    open var expectedTravelTime: TimeInterval { return 0 }
    open var distance: CLLocationDistance { return 0 }
}
public struct MKDirectionsTransportType: OptionSet { public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
    public static var automobile: MKDirectionsTransportType { return MKDirectionsTransportType(rawValue: 1) }
    public static var walking: MKDirectionsTransportType { return MKDirectionsTransportType(rawValue: 2) } }
open class MKDirections: NSObject {
    open class Request: NSObject { open var source: MKMapItem?; open var destination: MKMapItem?; open var transportType: MKDirectionsTransportType = .automobile; open var requestsAlternateRoutes: Bool = false }
    open class Response: NSObject { open var routes: [MKRoute] { return [] } }
    public init(request: MKDirections.Request) {}
    open func calculate(completionHandler: @escaping @Sendable (MKDirections.Response?, (any Error)?) -> Void) {
        guard let routes = MKDirections.simulatedRoutes else { return }
        let response: Response = _SimulatedDirectionsResponse(routes)
        DispatchQueue.global().asyncAfter(deadline: .now() + MKDirections.simulatedDelay) { [weak self] in
            if self?.cancelled == true { return }
            completionHandler(response, nil)
        }
    }
    open func calculate() async throws -> MKDirections.Response { return Response() }
    open func cancel() { cancelled = true }

    // Simulation hooks for ios/LinuxCheck/main.swift (not in the SDK): when simulatedRoutes
    // is set, calculate(completionHandler:) answers with them from a background queue after
    // simulatedDelay seconds, unless cancelled first.
    public static var simulatedRoutes: [MKRoute]?
    public static var simulatedDelay: Double = 0.1
    private var cancelled: Bool = false
}
private final class _SimulatedDirectionsResponse: MKDirections.Response {
    let simulated: [MKRoute]
    init(_ routes: [MKRoute]) { simulated = routes; super.init() }
    override var routes: [MKRoute] { return simulated }
}
open class MKLocalSearchCompletion: NSObject { open var title: String { return "" }; open var subtitle: String { return "" } }
open class MKLocalPointsOfInterestRequest: NSObject {}
open class MKLocalSearch: NSObject {
    open class Request: NSObject { public override init() {}; public init(completion: MKLocalSearchCompletion) {}; open var naturalLanguageQuery: String?; open var region: MKCoordinateRegion = MKCoordinateRegion() }
    open class Response: NSObject { open var mapItems: [MKMapItem] { return [] } }
    public init(request: MKLocalSearch.Request) {}
    public init(request: MKLocalPointsOfInterestRequest) {}
    open func start(completionHandler: @escaping @MainActor @Sendable (MKLocalSearch.Response?, (any Error)?) -> Void) {
        guard let response = MKLocalSearch.simulatedResponse else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { completionHandler(response, nil) } }
    }
    open func start() async throws -> MKLocalSearch.Response { return Response() }
    open func cancel() {}

    // Simulation hook for ios/LinuxCheck/main.swift (not in the SDK): when set,
    // start(completionHandler:) answers with it on the main queue.
    public static var simulatedResponse: MKLocalSearch.Response?
}
public protocol MKLocalSearchCompleterDelegate: NSObjectProtocol {}
open class MKLocalSearchCompleter: NSObject {
    public struct ResultType: OptionSet { public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
        public static var address: ResultType { return ResultType(rawValue: 1) }
        public static var pointOfInterest: ResultType { return ResultType(rawValue: 2) }
        public static var query: ResultType { return ResultType(rawValue: 4) } }
    public override init() {}
    weak open var delegate: MKLocalSearchCompleterDelegate?
    open var queryFragment: String = ""
    open var region: MKCoordinateRegion = MKCoordinateRegion()
    open var resultTypes: ResultType = []
    open var results: [MKLocalSearchCompletion] { return [] }
    open func cancel() {}
}
