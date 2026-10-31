// Linux stand-in for the parts of AppIntents the app uses, for ios/LinuxCheck only.
// Requirement names and types follow developer.apple.com documentation JSON (iOS 16/17).

import Foundation

public struct LocalizedStringResource: ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: DefaultStringInterpolation) {}
}

public struct IntentDescription {
    public init(_ descriptionText: LocalizedStringResource) {}
}

public struct IntentDialog: ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: DefaultStringInterpolation) {}
}

public protocol IntentResult {}
public protocol ProvidesDialog {}

public struct _DialogResult: IntentResult, ProvidesDialog {}

extension IntentResult where Self == _DialogResult {
    public static func result(dialog: IntentDialog) -> _DialogResult { return _DialogResult() }
}

public protocol ParameterSummary {}

@propertyWrapper
public final class IntentParameter<Value>: @unchecked Sendable {
    private var storage: Value?
    public init(title: LocalizedStringResource, description: LocalizedStringResource? = nil, default defaultValue: Value? = nil) {
        storage = defaultValue
    }
    public var wrappedValue: Value {
        get { return storage! }
        set { storage = newValue }
    }
    public var projectedValue: IntentParameter<Value> { return self }
}

public protocol AppIntent: Sendable {
    associatedtype PerformResult: IntentResult
    associatedtype SummaryContent: ParameterSummary
    static var title: LocalizedStringResource { get }
    static var description: IntentDescription? { get }
    static var openAppWhenRun: Bool { get }
    static var parameterSummary: Self.SummaryContent { get }
    init()
    func perform() async throws -> Self.PerformResult
}

extension AppIntent {
    public static var description: IntentDescription? { return nil }
    public static var openAppWhenRun: Bool { return false }
    public typealias Parameter<Value> = IntentParameter<Value>
    public typealias Summary = IntentParameterSummary<Self>
}

public struct ParameterSummaryString<Intent: AppIntent>: ExpressibleByStringInterpolation {
    public struct StringInterpolation: StringInterpolationProtocol {
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) {}
        public mutating func appendInterpolation<V>(_ keyPath: KeyPath<Intent, IntentParameter<V>>) {}
    }
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: StringInterpolation) {}
}

public struct IntentParameterSummary<Intent: AppIntent>: ParameterSummary {
    @resultBuilder
    public struct ParameterKeyPathsBuilder {
        public static func buildExpression<V>(_ keyPath: KeyPath<Intent, IntentParameter<V>>) -> PartialKeyPath<Intent> { return keyPath }
        public static func buildBlock(_ components: PartialKeyPath<Intent>...) -> [PartialKeyPath<Intent>] { return components }
    }
    public init(_ string: ParameterSummaryString<Intent>, table: String? = nil) {}
    public init(_ string: ParameterSummaryString<Intent>, table: String? = nil,
                @ParameterKeyPathsBuilder _ additionalParameterKeyPaths: () -> [PartialKeyPath<Intent>]) {}
}

public struct AppShortcutPhraseToken {
    public static let applicationName = AppShortcutPhraseToken()
}

public struct AppShortcutPhrase<Intent: AppIntent>: ExpressibleByStringInterpolation {
    public struct StringInterpolation: StringInterpolationProtocol {
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) {}
        public mutating func appendInterpolation(_ token: AppShortcutPhraseToken) {}
    }
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: StringInterpolation) {}
}

public struct AppShortcut {
    public init<Intent: AppIntent>(intent: Intent, phrases: [AppShortcutPhrase<Intent>], shortTitle: LocalizedStringResource, systemImageName: String) {}
}

@resultBuilder
public struct AppShortcutsBuilder {
    public static func buildBlock(_ components: AppShortcut...) -> [AppShortcut] { return components }
}

public protocol AppShortcutsProvider {
    @AppShortcutsBuilder static var appShortcuts: [AppShortcut] { get }
}
