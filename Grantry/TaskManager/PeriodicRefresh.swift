import SwiftUI

extension View {
    /// Ruft `refresh` beim Erscheinen und danach alle `interval` auf, solange die Ansicht angezeigt wird; `task` endet
    /// beim Verschwinden (Tabs „Benutzer“ und „Dienste“: utmpx bzw. `launchctl print`, beides nur lesend).
    func refreshesPeriodically(every interval: Duration,
                               _ refresh: @escaping @MainActor @Sendable () async -> Void) -> some View {
        task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }
}
