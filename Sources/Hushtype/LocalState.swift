import SwiftUI

/// View-local state without writing `@State` (in this SDK `@State` is a macro whose plugin ships with
/// Xcode only, and this project builds with the Command Line Tools). Wraps SwiftUI's own `State`
/// storage, so it costs the same as `@State`: no object or Combine publisher per view, which matters
/// for rows in long lists.
@propertyWrapper
struct Local<T>: DynamicProperty {
    private var state: State<T>

    init(wrappedValue: T) { state = State(initialValue: wrappedValue) }

    var wrappedValue: T {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    var projectedValue: Binding<T> { state.projectedValue }
}
