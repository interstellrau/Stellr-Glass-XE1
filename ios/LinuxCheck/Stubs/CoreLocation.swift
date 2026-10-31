import Foundation
public typealias CLLocationDegrees = Double
public typealias CLLocationDistance = Double
public typealias CLLocationAccuracy = Double
public struct CLLocationCoordinate2D { public var latitude: CLLocationDegrees; public var longitude: CLLocationDegrees
    public init() { latitude = 0; longitude = 0 }
    public init(latitude: CLLocationDegrees, longitude: CLLocationDegrees) { self.latitude = latitude; self.longitude = longitude } }
public let kCLLocationCoordinate2DInvalid = CLLocationCoordinate2D(latitude: -180, longitude: -180)
public let kCLLocationAccuracyBestForNavigation: CLLocationAccuracy = -2
public let kCLLocationAccuracyHundredMeters: CLLocationAccuracy = 100
public enum CLAuthorizationStatus: Int32 { case notDetermined, restricted, denied, authorizedAlways, authorizedWhenInUse }
public enum CLActivityType: Int { case other = 1, automotiveNavigation, fitness, otherNavigation, airborne }
public struct CLError: Error { public enum Code: Int { case locationUnknown = 0, denied }; public var code: Code { return .denied } }
open class CLLocation: NSObject {
    open var coordinate: CLLocationCoordinate2D { return CLLocationCoordinate2D() }
    open var horizontalAccuracy: CLLocationAccuracy { return 5 }
    open var verticalAccuracy: CLLocationAccuracy { return 5 }
    open var altitude: CLLocationDistance { return 0 }
    open var speed: Double { return 0 }
    open var course: Double { return 0 }
    open var timestamp: Date { return Date() }
    open func distance(from location: CLLocation) -> CLLocationDistance { return 0 }
}
public protocol CLLocationManagerDelegate: NSObjectProtocol {}
open class CLLocationManager: NSObject {
    public override init() {}
    weak open var delegate: CLLocationManagerDelegate?
    open var authorizationStatus: CLAuthorizationStatus { return .notDetermined }
    open var desiredAccuracy: CLLocationAccuracy = 0
    open var distanceFilter: CLLocationDistance = 0
    open var activityType: CLActivityType = .other
    open var allowsBackgroundLocationUpdates: Bool = false
    open var pausesLocationUpdatesAutomatically: Bool = true
    open func requestWhenInUseAuthorization() {}
    open func startUpdatingLocation() {}
    open func stopUpdatingLocation() {}
}
