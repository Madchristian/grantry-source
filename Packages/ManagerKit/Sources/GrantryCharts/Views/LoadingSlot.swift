import SwiftUI

/// Platz für einen Inhalt, der beim Erscheinen einmal geladen wird: bis dahin `placeholder`, danach `content`. Die Ladung
/// hängt am immer gefüllten Platz, nie am bedingten Inhalt. Eine leere `Group { if let … }` erscheint in einem Stapel
/// nicht, ihr `.task` startet also nie (#479; der Steckbrief „Dieser Mac“ fehlte bis 2026.11.9, Build 1492).
public struct LoadingSlot<Value, Content: View, Placeholder: View>: View {
    private let value: Value?
    private let content: (Value) -> Content
    private let placeholder: () -> Placeholder
    private let load: @MainActor () async -> Void

    public init(_ value: Value?, @ViewBuilder content: @escaping (Value) -> Content,
                @ViewBuilder placeholder: @escaping () -> Placeholder, load: @escaping @MainActor () async -> Void) {
        self.value = value
        self.content = content
        self.placeholder = placeholder
        self.load = load
    }

    public var body: some View {
        Group {
            if let value {
                content(value)
            } else {
                placeholder()
            }
        }
        .task { await load() }
    }
}
