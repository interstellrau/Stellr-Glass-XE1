// Linux stand-in for the parts of SwiftUI the app uses, for ios/LinuxCheck only. Shapes and
// labels follow the iOS 17+ SDK declarations (developer.apple.com documentation JSON), so the
// views type-check against the same initializers and modifiers. Nothing here renders.
// Simplifications: View isn't @MainActor here (it is on the iOS 26 SDK), modifiers return a
// concrete wrapper instead of `some View`, and toolbar items are plain views.

import Foundation
import Combine
import UIKit

// MARK: - Core

public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Self.Body { get }
}

extension Never: View {
    public typealias Body = Never
    public var body: Never { fatalError() }
}

public struct EmptyView: View {
    public init() {}
    public var body: Never { fatalError() }
}

public struct TupleView<T>: View {
    public init() {}
    public var body: Never { fatalError() }
}

public struct _ConditionalContent<TrueContent: View, FalseContent: View>: View {
    public init() {}
    public var body: Never { fatalError() }
}

public struct AnyView: View {
    public init<V: View>(_ view: V) {}
    public var body: Never { fatalError() }
}

extension Optional: View where Wrapped: View {
    public typealias Body = Never
    public var body: Never { fatalError() }
}

public struct _Modified<Content>: View {
    public init() {}
    public var body: Never { fatalError() }
}

@resultBuilder
public struct ViewBuilder {
    public static func buildBlock() -> EmptyView { return EmptyView() }
    public static func buildBlock<Content: View>(_ content: Content) -> Content { return content }
    public static func buildBlock<each Content: View>(_ content: repeat each Content) -> TupleView<(repeat each Content)> { return TupleView() }
    public static func buildExpression<Content: View>(_ content: Content) -> Content { return content }
    public static func buildIf<Content: View>(_ content: Content?) -> Content? { return content }
    public static func buildEither<T: View, F: View>(first: T) -> _ConditionalContent<T, F> { return _ConditionalContent() }
    public static func buildEither<T: View, F: View>(second: F) -> _ConditionalContent<T, F> { return _ConditionalContent() }
    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView { return AnyView(content) }
}

public struct LocalizedStringKey: ExpressibleByStringInterpolation, Equatable {
    public init(_ value: String) {}
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: DefaultStringInterpolation) {}
}

// MARK: - Layout values

public enum Axis { case horizontal, vertical
    public struct Set: OptionSet { public let rawValue: Int8; public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1); public static let vertical = Set(rawValue: 2) }
}

public struct Edge {
    public struct Set: OptionSet {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1)
        public static let leading = Set(rawValue: 2)
        public static let bottom = Set(rawValue: 4)
        public static let trailing = Set(rawValue: 8)
        public static let all = Set(rawValue: 15)
        public static let horizontal = Set(rawValue: 10)
        public static let vertical = Set(rawValue: 5)
    }
}

public enum VerticalEdge { case top, bottom }
public enum HorizontalEdge { case leading, trailing }

public struct HorizontalAlignment: Equatable {
    public static let leading = HorizontalAlignment()
    public static let center = HorizontalAlignment()
    public static let trailing = HorizontalAlignment()
}

public struct VerticalAlignment: Equatable {
    public static let top = VerticalAlignment()
    public static let center = VerticalAlignment()
    public static let bottom = VerticalAlignment()
    public static let firstTextBaseline = VerticalAlignment()
}

public struct Alignment: Equatable {
    public static let leading = Alignment()
    public static let center = Alignment()
    public static let trailing = Alignment()
    public static let top = Alignment()
    public static let bottom = Alignment()
}

public struct EdgeInsets: Equatable {
    public init() {}
    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {}
}

public enum ContentMode { case fit, fill }
public enum TextAlignment { case leading, center, trailing }
public enum Visibility { case automatic, visible, hidden }
public enum RoundedCornerStyle { case circular, continuous }
public struct FillStyle { public init() {} }

// MARK: - Styles

public protocol ShapeStyle {}

public struct Color: View, ShapeStyle, Equatable {
    public var body: Never { fatalError() }
    public static let red = Color()
    public static let orange = Color()
    public static let green = Color()
    public static let blue = Color()
    public static let white = Color()
    public static let primary = Color()
    public static let secondary = Color()
    public static let accentColor = Color()
    public func opacity(_ opacity: Double) -> Color { return self }
}

extension ShapeStyle where Self == Color {
    public static var red: Color { return Color() }
    public static var orange: Color { return Color() }
    public static var green: Color { return Color() }
    public static var blue: Color { return Color() }
    public static var white: Color { return Color() }
}

public struct HierarchicalShapeStyle: ShapeStyle {
    public static let primary = HierarchicalShapeStyle()
    public static let secondary = HierarchicalShapeStyle()
}

extension ShapeStyle where Self == HierarchicalShapeStyle {
    public static var primary: HierarchicalShapeStyle { return HierarchicalShapeStyle() }
    public static var secondary: HierarchicalShapeStyle { return HierarchicalShapeStyle() }
}

public struct Material: ShapeStyle {
    public static let regularMaterial = Material()
    public static let bar = Material()
}

extension ShapeStyle where Self == Material {
    public static var regularMaterial: Material { return Material() }
    public static var bar: Material { return Material() }
}

public struct Font: Equatable {
    public enum TextStyle { case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2 }
    public enum Design { case `default`, serif, rounded, monospaced }
    public struct Weight: Equatable {
        public static let regular = Weight()
        public static let medium = Weight()
        public static let semibold = Weight()
        public static let bold = Weight()
    }
    public static let largeTitle = Font()
    public static let title = Font()
    public static let title2 = Font()
    public static let title3 = Font()
    public static let headline = Font()
    public static let subheadline = Font()
    public static let body = Font()
    public static let callout = Font()
    public static let footnote = Font()
    public static let caption = Font()
    public static let caption2 = Font()
    public static func system(_ style: Font.TextStyle, design: Font.Design? = nil, weight: Font.Weight? = nil) -> Font { return Font() }
    public static func system(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font { return Font() }
    public func weight(_ weight: Font.Weight) -> Font { return self }
}

public protocol PrimitiveButtonStyle {}
public struct BorderlessButtonStyle: PrimitiveButtonStyle {}
public struct PlainButtonStyle: PrimitiveButtonStyle {}
public struct BorderedButtonStyle: PrimitiveButtonStyle {}
public struct BorderedProminentButtonStyle: PrimitiveButtonStyle {}
extension PrimitiveButtonStyle where Self == BorderlessButtonStyle { public static var borderless: BorderlessButtonStyle { return BorderlessButtonStyle() } }
extension PrimitiveButtonStyle where Self == PlainButtonStyle { public static var plain: PlainButtonStyle { return PlainButtonStyle() } }
extension PrimitiveButtonStyle where Self == BorderedButtonStyle { public static var bordered: BorderedButtonStyle { return BorderedButtonStyle() } }
extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle { public static var borderedProminent: BorderedProminentButtonStyle { return BorderedProminentButtonStyle() } }

public protocol PickerStyle {}
public struct SegmentedPickerStyle: PickerStyle {}
extension PickerStyle where Self == SegmentedPickerStyle { public static var segmented: SegmentedPickerStyle { return SegmentedPickerStyle() } }

public protocol TextSelectability {}
public struct EnabledTextSelectability: TextSelectability {}
extension TextSelectability where Self == EnabledTextSelectability { public static var enabled: EnabledTextSelectability { return EnabledTextSelectability() } }

public struct TextInputAutocapitalization { public static let never = TextInputAutocapitalization() }
public struct SubmitLabel { public static let search = SubmitLabel(); public static let done = SubmitLabel() }
public struct SubmitTriggers: OptionSet { public let rawValue: Int; public init(rawValue: Int) { self.rawValue = rawValue }; public static let text = SubmitTriggers(rawValue: 1) }
public struct ScrollDismissesKeyboardMode { public static let interactively = ScrollDismissesKeyboardMode(); public static let immediately = ScrollDismissesKeyboardMode() }
public enum NavigationBarItem { public enum TitleDisplayMode { case automatic, inline, large } }
public struct ButtonRole: Equatable { public static let destructive = ButtonRole(); public static let cancel = ButtonRole() }

// MARK: - State

@propertyWrapper @dynamicMemberLookup
public struct Binding<Value> {
    private let getter: () -> Value
    private let setter: (Value) -> Void
    public init(get: @escaping @Sendable () -> Value, set: @escaping @Sendable (Value) -> Void) {
        getter = get
        setter = set
    }
    public init(projectedValue: Binding<Value>) {
        getter = projectedValue.getter
        setter = projectedValue.setter
    }
    public var wrappedValue: Value {
        get { return getter() }
        nonmutating set { setter(newValue) }
    }
    public var projectedValue: Binding<Value> { return self }
    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> { fatalError() }
}

@propertyWrapper
public struct State<Value> {
    public init(wrappedValue value: Value) {}
    public init() where Value: ExpressibleByNilLiteral {}
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { fatalError() }
}

@propertyWrapper
public struct ObservedObject<ObjectType: ObservableObject> {
    @dynamicMemberLookup
    public struct Wrapper {
        public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>) -> Binding<Subject> { fatalError() }
    }
    public init(wrappedValue: ObjectType) {}
    public var wrappedValue: ObjectType { fatalError() }
    public var projectedValue: ObservedObject<ObjectType>.Wrapper { fatalError() }
}

@propertyWrapper
public struct FocusState<Value: Hashable> {
    public struct Binding {
        public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    }
    public init() where Value == Bool {}
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: FocusState<Value>.Binding { fatalError() }
}

public enum ScenePhase: Equatable { case background, inactive, active }
public struct DismissAction { public func callAsFunction() {} }

public struct EnvironmentValues {
    public var scenePhase: ScenePhase { return .active }
    public var dismiss: DismissAction { return DismissAction() }
}

@propertyWrapper
public struct Environment<Value> {
    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {}
    public var wrappedValue: Value { fatalError() }
}

// MARK: - Views

public struct Text: View, Equatable {
    public var body: Never { fatalError() }
    public init(_ key: LocalizedStringKey) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ content: S) {}
    public init(verbatim content: String) {}
    public func font(_ font: Font?) -> Text { return self }
    public func fontWeight(_ weight: Font.Weight?) -> Text { return self }
}

public struct Image: View {
    public enum Interpolation { case none, low, medium, high }
    public enum ResizingMode { case tile, stretch }
    public var body: Never { fatalError() }
    public init(systemName: String) {}
    public init(uiImage: UIImage) {}
    public func resizable(capInsets: EdgeInsets = EdgeInsets(), resizingMode: Image.ResizingMode = .stretch) -> Image { return self }
    public func interpolation(_ interpolation: Image.Interpolation) -> Image { return self }
}

public struct Label<Title: View, Icon: View>: View {
    public var body: Never { fatalError() }
    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {}
}

extension Label where Title == Text, Icon == Image {
    public init(_ titleKey: LocalizedStringKey, systemImage name: String) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage name: String) {}
}

public struct Button<Label: View>: View {
    public var body: Never { fatalError() }
    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {}
    public init(role: ButtonRole?, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {}
}

extension Button where Label == Text {
    public init(_ titleKey: LocalizedStringKey, action: @escaping () -> Void) {}
    public init(_ titleKey: LocalizedStringKey, role: ButtonRole?, action: @escaping () -> Void) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, action: @escaping () -> Void) {}
}

public struct Toggle<Label: View>: View {
    public var body: Never { fatalError() }
}
extension Toggle where Label == Text {
    public init(_ titleKey: LocalizedStringKey, isOn: Binding<Bool>) {}
}

public struct TextField<Label: View>: View {
    public var body: Never { fatalError() }
}
extension TextField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {}
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, axis: Axis) {}
}

public struct SecureField<Label: View>: View {
    public var body: Never { fatalError() }
}
extension SecureField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {}
}

public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View {
    public var body: Never { fatalError() }
}
extension Picker where Label == Text {
    public init(_ titleKey: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {}
}

public struct Form<Content: View>: View {
    public var body: Never { fatalError() }
    public init(@ViewBuilder content: () -> Content) {}
}

public struct List<SelectionValue: Hashable, Content: View>: View {
    public var body: Never { fatalError() }
}
extension List where SelectionValue == Never {
    public init(@ViewBuilder content: () -> Content) {}
}

public struct Section<Parent: View, Content: View, Footer: View>: View {
    public var body: Never { fatalError() }
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent, @ViewBuilder footer: () -> Footer) {}
}
extension Section where Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) {}
}
extension Section where Parent == EmptyView, Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content) {}
}

public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    public var body: Never { fatalError() }
}
extension ForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {}
}

public struct NavigationStack<Root: View>: View {
    public var body: Never { fatalError() }
    public init(@ViewBuilder root: () -> Root) {}
}

public struct NavigationLink<Label: View, Destination: View>: View {
    public var body: Never { fatalError() }
    public init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Label) {}
}

public struct TabView<SelectionValue: Hashable, Content: View>: View {
    public var body: Never { fatalError() }
}
extension TabView where SelectionValue == Int {
    public init(@ViewBuilder content: () -> Content) {}
}

public struct HStack<Content: View>: View {
    public var body: Never { fatalError() }
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
}

public struct VStack<Content: View>: View {
    public var body: Never { fatalError() }
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
}

public struct ScrollView<Content: View>: View {
    public var body: Never { fatalError() }
    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {}
}

public struct Group<Content: View>: View {
    public var body: Never { fatalError() }
    public init(@ViewBuilder content: () -> Content) {}
}

public struct Spacer: View {
    public var body: Never { fatalError() }
    public init(minLength: CGFloat? = nil) {}
}

public struct Divider: View {
    public var body: Never { fatalError() }
    public init() {}
}

public struct ProgressView<Label: View, CurrentValueLabel: View>: View {
    public var body: Never { fatalError() }
}
extension ProgressView where Label == EmptyView, CurrentValueLabel == EmptyView {
    public init() {}
    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0) {}
}

public struct LabeledContent<Label: View, Content: View>: View {
    public var body: Never { fatalError() }
}
extension LabeledContent where Label == Text, Content == Text {
    public init<S: StringProtocol>(_ titleKey: LocalizedStringKey, value: S) {}
    @_disfavoredOverload public init<S1: StringProtocol, S2: StringProtocol>(_ title: S1, value: S2) {}
}

public protocol TimelineSchedule {}
public struct PeriodicTimelineSchedule: TimelineSchedule {}
extension TimelineSchedule where Self == PeriodicTimelineSchedule {
    public static func periodic(from startDate: Date, by interval: TimeInterval) -> PeriodicTimelineSchedule { return PeriodicTimelineSchedule() }
}
public struct TimelineViewDefaultContext { public let date: Date }
public struct TimelineView<Schedule: TimelineSchedule, Content: View>: View {
    public var body: Never { fatalError() }
    public init(_ schedule: Schedule, @ViewBuilder content: @escaping (TimelineViewDefaultContext) -> Content) {}
}

public enum ToolbarItemPlacement { case automatic, primaryAction, confirmationAction, cancellationAction }
public struct ToolbarItem<ID, Content: View>: View {
    public var body: Never { fatalError() }
}
extension ToolbarItem where ID == () {
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {}
}

// MARK: - Shapes

public protocol Shape: View {}
public protocol InsettableShape: Shape {}

extension Shape {
    public func fill<S: ShapeStyle>(_ content: S, style: FillStyle = FillStyle()) -> _Modified<Self> { return _Modified() }
}

public struct Circle: InsettableShape {
    public var body: Never { fatalError() }
    public init() {}
}

public struct Rectangle: InsettableShape {
    public var body: Never { fatalError() }
    public init() {}
}

public struct RoundedRectangle: InsettableShape {
    public var body: Never { fatalError() }
    public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {}
}

// MARK: - Modifiers

extension View {
    public func font(_ font: Font?) -> _Modified<Self> { return _Modified() }
    public func fontWeight(_ weight: Font.Weight?) -> _Modified<Self> { return _Modified() }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> _Modified<Self> { return _Modified() }
    public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> _Modified<Self> { return _Modified() }
    public func padding(_ length: CGFloat) -> _Modified<Self> { return _Modified() }
    public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> _Modified<Self> { return _Modified() }
    public func frame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil, minHeight: CGFloat? = nil,
                      idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil, alignment: Alignment = .center) -> _Modified<Self> { return _Modified() }
    public func background<S: ShapeStyle>(_ style: S, ignoresSafeAreaEdges edges: Edge.Set = .all) -> _Modified<Self> { return _Modified() }
    public func background<S: ShapeStyle, T: InsettableShape>(_ style: S, in shape: T, fillStyle: FillStyle = FillStyle()) -> _Modified<Self> { return _Modified() }
    public func navigationTitle(_ titleKey: LocalizedStringKey) -> _Modified<Self> { return _Modified() }
    @_disfavoredOverload public func navigationTitle<S: StringProtocol>(_ title: S) -> _Modified<Self> { return _Modified() }
    public func navigationBarTitleDisplayMode(_ displayMode: NavigationBarItem.TitleDisplayMode) -> _Modified<Self> { return _Modified() }
    public func lineLimit(_ number: Int?) -> _Modified<Self> { return _Modified() }
    public func lineLimit(_ limit: ClosedRange<Int>) -> _Modified<Self> { return _Modified() }
    public func buttonStyle<S: PrimitiveButtonStyle>(_ style: S) -> _Modified<Self> { return _Modified() }
    public func disabled(_ disabled: Bool) -> _Modified<Self> { return _Modified() }
    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (V, V) -> Void) -> _Modified<Self> { return _Modified() }
    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> _Modified<Self> { return _Modified() }
    public func autocorrectionDisabled(_ disable: Bool = true) -> _Modified<Self> { return _Modified() }
    public func textSelection<S: TextSelectability>(_ selectability: S) -> _Modified<Self> { return _Modified() }
    public func safeAreaInset<V: View>(edge: VerticalEdge, alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
                                       @ViewBuilder content: () -> V) -> _Modified<Self> { return _Modified() }
    public func clipShape<S: Shape>(_ shape: S, style: FillStyle = FillStyle()) -> _Modified<Self> { return _Modified() }
    public func aspectRatio(_ aspectRatio: CGFloat? = nil, contentMode: ContentMode) -> _Modified<Self> { return _Modified() }
    public func scaledToFit() -> _Modified<Self> { return _Modified() }
    public func accessibilityLabel(_ labelKey: LocalizedStringKey) -> _Modified<Self> { return _Modified() }
    public func tint(_ tint: Color?) -> _Modified<Self> { return _Modified() }
    public func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> _Modified<Self> { return _Modified() }
    public func submitLabel(_ submitLabel: SubmitLabel) -> _Modified<Self> { return _Modified() }
    public func onSubmit(of triggers: SubmitTriggers = .text, _ action: @escaping () -> Void) -> _Modified<Self> { return _Modified() }
    public func focused(_ condition: FocusState<Bool>.Binding) -> _Modified<Self> { return _Modified() }
    public func sheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                     @ViewBuilder content: @escaping () -> Content) -> _Modified<Self> { return _Modified() }
    public func scrollDismissesKeyboard(_ mode: ScrollDismissesKeyboardMode) -> _Modified<Self> { return _Modified() }
    public func pickerStyle<S: PickerStyle>(_ style: S) -> _Modified<Self> { return _Modified() }
    public func multilineTextAlignment(_ alignment: TextAlignment) -> _Modified<Self> { return _Modified() }
    public func listRowInsets(_ insets: EdgeInsets?) -> _Modified<Self> { return _Modified() }
    public func id<ID: Hashable>(_ id: ID) -> _Modified<Self> { return _Modified() }
    public func contentShape<S: Shape>(_ shape: S, eoFill: Bool = false) -> _Modified<Self> { return _Modified() }
    public func tag<V: Hashable>(_ tag: V) -> _Modified<Self> { return _Modified() }
    public func tabItem<V: View>(@ViewBuilder _ label: () -> V) -> _Modified<Self> { return _Modified() }
    public func refreshable(action: @escaping @Sendable () async -> Void) -> _Modified<Self> { return _Modified() }
    public func toolbar<Content: View>(@ViewBuilder content: () -> Content) -> _Modified<Self> { return _Modified() }
    public func confirmationDialog<A: View, M: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>,
                                                     titleVisibility: Visibility = .automatic,
                                                     @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> _Modified<Self> { return _Modified() }
    public func alert<A: View, M: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>,
                                        @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> _Modified<Self> { return _Modified() }
}

// MARK: - App

public protocol Scene {}

@resultBuilder
public struct SceneBuilder {
    public static func buildBlock<Content: Scene>(_ content: Content) -> Content { return content }
}

public protocol App {
    associatedtype Body: Scene
    @SceneBuilder var body: Self.Body { get }
    init()
}

extension App {
    public static func main() {}
}

public struct WindowGroup<Content: View>: Scene {
    public init(@ViewBuilder content: () -> Content) {}
}
