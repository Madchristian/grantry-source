import GrantryCharts
import ManagerKit
import SwiftUI

/// Tab „Wachbuch“ (TM-12.5, Spec 2026-11-08 § 5.1) aus einer fertig zugeordneten Reihe (`WatchbookScreen`): Zustandszeile,
/// Umschalter Zeitraum, Ereignisleiste, Spuren, Thermikband und Zeitmarke (`WatchbookBoard`), rechts „Zu diesem
/// Zeitpunkt“ und darunter „Befunde“ (TM-12.6). Liest selbst nichts; die Werte unter der Zeitmarke kommen aus der
/// Darstellung.
struct WatchbookView: View {
    let screen: WatchbookScreen
    @Binding var period: WatchbookPeriod
    @Binding var marker: Int?
    let analysis: WatchbookAnalysis
    @Binding var selectedFinding: String?
    let jump: (String) -> Void
    let enable: () -> Void

    var body: some View {
        WatchbookBoard(status: screen.status, state: screen.state, readout: screen.readout(at: marker),
                       detail: screen.presentation.detail, period: $period,
                       periods: WatchbookPeriod.allCases.map { ($0, $0.title) }, marker: $marker, analysis: analysis,
                       selectedFinding: $selectedFinding, jump: jump, enable: enable)
            .renderProbe("WatchbookView")
    }
}

/// Liest die verdichtete Reihe des gewählten Zeitraums, solange der Tab sichtbar ist (§ 4.4): neu bei anderem Zeitraum,
/// anderer Breite oder Einstellung und danach je neuer Spalte – höchstens alle 10 s, im 7-Tage-Zeitraum etwa alle
/// 10 min. Die Zeitmarke hängt an einem Zeitpunkt, nicht an einer Spalte: Sie bleibt stehen, während die Zeit
/// weiterläuft. Zur Zeitmarke liest er die größten Verbraucher (erst wenn sie kurz still steht, nicht bei jedem Schritt
/// des Ziehens); die Wahl eines Befunds setzt die Zeitmarke auf seinen Beginn, ebenso ein Zeitpunkt von außen (`focus`,
/// Mitteilung zu einem schweren Befund) samt passendem Zeitraum (`WatchbookFocus`).
struct WatchbookLoader: View {
    typealias Read = @Sendable (_ period: WatchbookPeriod, _ end: Date, _ width: Int) async -> WatchbookSeries
    typealias ReadConsumers = @Sendable (_ time: Date, _ window: TimeInterval) async -> WatchbookConsumers?

    let read: Read
    let readConsumers: ReadConsumers
    let isEnabled: Bool
    let recordingSince: Date?
    let enable: () -> Void
    let jump: (WatchbookJumpTarget) -> Void
    /// Zeitpunkt von außen, an den die Zeitmarke springen soll; `didFocus` meldet die Übernahme.
    let focus: Date?
    let didFocus: () -> Void
    /// Ob der Prozess eines Befunds noch derselbe ist (PID und Startzeit, `ProcessInspecting.liveness`).
    var liveness: (ProcessKey) -> ProcessLiveness = { LibprocProcessInspector().liveness(of: $0.pid) }
    var now: @Sendable () -> Date = Date.init
    var calendar = Calendar.current
    var physicalMemory = Double(ProcessInfo.processInfo.physicalMemory)

    @State private var period: WatchbookPeriod
    @State private var markerTime: Date?
    @State private var series: WatchbookSeries?
    @State private var screen: WatchbookScreen?
    @State private var columns = 0
    @State private var selectedFinding: String?
    @State private var consumers = WatchbookConsumerState.loading

    /// Spalten springen in diesen Schritten mit der Breite, damit Ziehen am Fenster nicht jeden Bildpunkt neu liest.
    nonisolated static let columnStep = 16
    nonisolated static let minimumColumns = 60
    static let minimumRefresh: TimeInterval = 10
    /// So lange steht die Zeitmarke still, bevor die Verbraucher gelesen werden.
    static let consumerDelay: Duration = .milliseconds(150)

    init(read: @escaping Read, readConsumers: @escaping ReadConsumers, isEnabled: Bool, recordingSince: Date?,
         enable: @escaping () -> Void, jump: @escaping (WatchbookJumpTarget) -> Void, focus: Date? = nil,
         didFocus: @escaping () -> Void = {}, period: WatchbookPeriod = .day) {
        self.read = read
        self.readConsumers = readConsumers
        self.isEnabled = isEnabled
        self.recordingSince = recordingSince
        self.enable = enable
        self.jump = jump
        self.focus = focus
        self.didFocus = didFocus
        _period = State(initialValue: period)
    }

    var body: some View {
        let screen = screen ?? WatchbookScreen(presentation(of: nil))
        let marker = marker
        let analysis = screen.analysis(at: marker.wrappedValue, consumers: consumers, liveness: liveness)
        WatchbookView(screen: screen, period: $period, marker: marker, analysis: analysis.content,
                      selectedFinding: findingSelection(screen),
                      jump: { id in analysis.targets[id].map(jump) }, enable: enable)
            .onGeometryChange(for: Int.self) { proxy in
                Self.columns(forBoardWidth: proxy.size.width)
            } action: { columns = $0 }
            .task(id: Reload(period: period, isEnabled: isEnabled, columns: columns)) { await refresh() }
            .onChange(of: recordingSince) { rebuild() }
            .onChange(of: focus, initial: true) { apply(focus) }
            .task(id: ConsumerQuery(time: markerTime, columnDuration: series?.columnDuration)) { await loadConsumers() }
    }

    private struct ConsumerQuery: Equatable {
        let time: Date?
        let columnDuration: TimeInterval?
    }

    private struct Reload: Equatable {
        let period: WatchbookPeriod
        let isEnabled: Bool
        let columns: Int
    }

    /// Zeitmarke als Spalte der aktuellen Reihe; außerhalb des Zeitraums keine.
    private var marker: Binding<Int?> {
        Binding {
            guard let markerTime, let series, series.range.contains(markerTime) else { return nil }
            return Int(markerTime.timeIntervalSince(series.range.lowerBound) / series.columnDuration)
        } set: { column in
            markerTime = column.flatMap { column in series?.time(ofColumn: column) }
            selectedFinding = nil
        }
    }

    /// Gewählter Befund; die Wahl setzt die Zeitmarke auf seinen Beginn.
    private func findingSelection(_ screen: WatchbookScreen) -> Binding<String?> {
        Binding {
            selectedFinding
        } set: { id in
            selectedFinding = id
            if let time = id.flatMap(UUID.init(uuidString:)).flatMap(screen.presentation.markerTime(ofFinding:)) {
                markerTime = time
            }
        }
    }

    /// Setzt Zeitraum und Zeitmarke auf einen Zeitpunkt von außen; liegt er außerhalb der Aufzeichnung, bleibt der
    /// Zeitraum und das Wachbuch zeigt das aktuelle Ende ohne Zeitmarke.
    private func apply(_ focus: Date?) {
        guard let focus else { return }
        didFocus()
        let target = WatchbookFocus(markerAt: focus, now: now(), recordingSince: recordingSince)
        if let target { period = target.period }
        markerTime = target?.marker
        selectedFinding = nil
    }

    /// Verbraucher an der Zeitmarke, außerhalb des Hauptthreads; bis zum ersten Ergebnis „wird gelesen“, danach bleibt
    /// das vorige stehen, bis das neue da ist.
    private func loadConsumers() async {
        guard let markerTime, let columnDuration = series?.columnDuration else {
            consumers = .loading
            return
        }
        do { try await Task.sleep(for: Self.consumerDelay) } catch { return }
        let readConsumers = readConsumers, window = WatchbookConsumers.window(columnDuration: columnDuration)
        let loaded = await Task.detached(priority: .utility) { await readConsumers(markerTime, window) }.value
        guard !Task.isCancelled else { return }
        consumers = .loaded(loaded)
    }

    nonisolated static func columns(forBoardWidth width: CGFloat) -> Int {
        let pixels = Int(WatchbookBoardLayout.graphWidth(forBoardWidth: width))
        return max(pixels / columnStep * columnStep, minimumColumns)
    }

    private func refresh() async {
        // Eine Reihe eines anderen Zeitraums passt nicht zur Zeitmarke; bei neuer Breite bleibt die alte bis zur neuen.
        if !isEnabled || series.map({ $0.range.upperBound.timeIntervalSince($0.range.lowerBound) != period.duration })
            ?? false {
            series = nil
        }
        rebuild()
        guard isEnabled, columns > 0 else { return }
        let read = read, period = period, columns = columns
        while !Task.isCancelled {
            // Außerhalb des Hauptthreads (§ 4.4 Regel 6): 7 Tage zu lesen dauert bis etwa 150 ms.
            let end = now()
            let loaded = await Task.detached(priority: .utility) { await read(period, end, columns) }.value
            guard !Task.isCancelled else { return }
            series = loaded
            rebuild()
            let interval = max(loaded.columnDuration, Self.minimumRefresh)
            try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval / 10))
        }
    }

    private func rebuild() {
        screen = WatchbookScreen(presentation(of: series))
    }

    private func presentation(of series: WatchbookSeries?) -> WatchbookPresentation {
        WatchbookPresentation(series: series, period: period, isEnabled: isEnabled, recordingSince: recordingSince,
                              physicalMemory: physicalMemory, calendar: calendar)
    }
}

// `WatchbookPreviewData` gibt es nur im Debug-Build.
#if DEBUG
#Preview("Wachbuch, 24 Stunden") {
    @Previewable @State var period = WatchbookPeriod.day
    @Previewable @State var marker: Int?
    @Previewable @State var selectedFinding: String?
    let screen = WatchbookScreen(WatchbookPreviewData.presentation(period))
    WatchbookView(screen: screen, period: $period, marker: $marker,
                  analysis: screen.analysis(at: marker, consumers: .loaded(nil), liveness: { _ in .absent }).content,
                  selectedFinding: $selectedFinding, jump: { _ in }, enable: {})
        .frame(width: 1240, height: 800)
        .instrumentBackground()
}

#Preview("Wachbuch aus") {
    let screen = WatchbookScreen(WatchbookPreviewData.presentation(.day, isEnabled: false))
    WatchbookView(screen: screen, period: .constant(.day), marker: .constant(nil),
                  analysis: screen.analysis(at: nil, consumers: .loading, liveness: { _ in .absent }).content,
                  selectedFinding: .constant(nil), jump: { _ in }, enable: {})
        .frame(width: 1240, height: 800)
        .instrumentBackground()
}
#endif
