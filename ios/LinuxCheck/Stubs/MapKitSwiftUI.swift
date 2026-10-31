// Linux stand-in for MapKit's SwiftUI API (iOS 17+), compiled into the MapKit stub module
// for ios/LinuxCheck only. Signatures follow developer.apple.com documentation JSON.

import Foundation
import SwiftUI

@MainActor @preconcurrency public protocol MapContent {}

extension Optional: MapContent where Wrapped: MapContent {}

public struct _TupleMapContent<T>: MapContent { public init() {} }
public struct _ConditionalMapContent<T: MapContent, F: MapContent>: MapContent { public init() {} }
public struct _ModifiedMapContent<C>: MapContent { public init() {} }

@resultBuilder
public struct MapContentBuilder {
    public static func buildBlock<C: MapContent>(_ content: C) -> C { return content }
    public static func buildBlock<each C: MapContent>(_ content: repeat each C) -> _TupleMapContent<(repeat each C)> { return _TupleMapContent() }
    public static func buildExpression<C: MapContent>(_ content: C) -> C { return content }
    public static func buildIf<C: MapContent>(_ content: C?) -> C? { return content }
    public static func buildEither<T: MapContent, F: MapContent>(first: T) -> _ConditionalMapContent<T, F> { return _ConditionalMapContent() }
    public static func buildEither<T: MapContent, F: MapContent>(second: F) -> _ConditionalMapContent<T, F> { return _ConditionalMapContent() }
}

public struct MapCameraPosition: Equatable {
    public static var automatic: MapCameraPosition { return MapCameraPosition() }
    public static func userLocation(followsHeading: Bool = false, fallback: MapCameraPosition) -> MapCameraPosition { return MapCameraPosition() }
    public static func region(_ region: MKCoordinateRegion) -> MapCameraPosition { return MapCameraPosition() }
    public static func rect(_ rect: MKMapRect) -> MapCameraPosition { return MapCameraPosition() }
}

public struct MapCameraBounds {}
public struct MapInteractionModes: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let all = MapInteractionModes(rawValue: 15)
}

public struct Map<Content: View>: View {
    public var body: Never { fatalError() }
}

public struct _MapContentView<C: MapContent>: View {
    public var body: Never { fatalError() }
}

extension Map {
    public init<C: MapContent>(position: Binding<MapCameraPosition>, bounds: MapCameraBounds? = nil,
                               interactionModes: MapInteractionModes = .all,
                               @MapContentBuilder content: () -> C) where Content == _MapContentView<C> {}
    public init<C: MapContent>(initialPosition: MapCameraPosition, bounds: MapCameraBounds? = nil,
                               interactionModes: MapInteractionModes = .all,
                               @MapContentBuilder content: () -> C) where Content == _MapContentView<C> {}
}

public struct UserAnnotation: MapContent {
    public init() {}
}

public struct MapPolyline: MapContent {
    public init(_ polyline: MKPolyline) {}
    public init(_ route: MKRoute) {}
}

extension MapContent {
    public func stroke<S: ShapeStyle>(_ content: S, lineWidth: CGFloat = 1) -> _ModifiedMapContent<Self> { return _ModifiedMapContent() }
}

public struct Marker<Label: View>: MapContent {}

extension Marker where Label == Text {
    public init(_ titleKey: LocalizedStringKey, coordinate: CLLocationCoordinate2D) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, coordinate: CLLocationCoordinate2D) {}
}

public struct MapUserLocationButton: View {
    public var body: Never { fatalError() }
    public init() {}
}

public struct MapCompass: View {
    public var body: Never { fatalError() }
    public init() {}
}

extension View {
    public func mapControls<C: View>(@ViewBuilder _ content: () -> C) -> _Modified<Self> { return _Modified() }
}
