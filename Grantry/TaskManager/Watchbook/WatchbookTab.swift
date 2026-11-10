import ManagerKit
import SwiftUI

/// Tab „Wachbuch“ mit dem Wachbuch der App: Einstellung „Wachbuch führen“, seit wann es aufzeichnet, und der lesende
/// Zugriff auf die verdichtete Reihe (`WatchbookSeriesReading`) und die Verbraucher an der Zeitmarke
/// (`WatchbookConsumerReading`); „Wachbuch einschalten“ setzt die Einstellung, Sprünge führen in den zuständigen Bereich
/// (TM-12.6). Ein Zeitpunkt aus einer Mitteilung (`MainWindowModel.watchbookMarker`) setzt die Zeitmarke (TM-12.8a).
struct WatchbookTab: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        let watchbook = appModel.watchbook
        let reader = appModel.watchbookSeries
        let consumers = appModel.watchbookConsumers
        let window = window
        WatchbookLoader(read: { await reader.series($0, endingAt: $1, width: $2) },
                        readConsumers: { await consumers.consumers(near: $0, within: $1) },
                        isEnabled: watchbook.isEnabled, recordingSince: watchbook.recordingSince,
                        enable: { watchbook.isEnabled = true }, jump: { window.show($0) },
                        focus: window.watchbookMarker, didFocus: { window.watchbookMarker = nil })
    }
}
