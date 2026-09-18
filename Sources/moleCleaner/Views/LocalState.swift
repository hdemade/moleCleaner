import Combine
import SwiftUI

/// Équivalent de `@State` sans macro : dans le SDK macOS 26, `@State` est une macro dont le
/// plugin (SwiftUIMacros) n'est livré qu'avec Xcode. Ce wrapper permet de compiler avec les
/// seules Command Line Tools.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    private final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        let box = box
        return Binding(get: { box.value }, set: { box.value = $0 })
    }
}
