/// Meldet Änderungen gebündelt: Das erste Event öffnet ein Fenster (Standard 10 s), alle bis zu dessen Ende
/// eintreffenden Events kommen dazu. Danach gehen bis zu `individualLimit` Events einzeln hinaus, mehr als eine
/// Sammelmeldung „N Änderungen“.
public actor ChangeNotifier {
    private let notifier: any UserNotifying
    private let window: Duration
    private let individualLimit: Int
    private let clock: any Clock<Duration>

    private var pending: [HistoryEvent] = []
    private var windowTask: Task<Void, Never>?
    /// Kennung des offenen Fensters; ein verspäteter Zeitgeber eines schon geleerten Fensters verfällt dadurch.
    private var windowID = 0

    public init(
        notifier: any UserNotifying,
        window: Duration = .seconds(10),
        individualLimit: Int = 3,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.notifier = notifier
        self.window = window
        self.individualLimit = individualLimit
        self.clock = clock
    }

    /// Nimmt Events ins laufende Fenster auf oder öffnet ein neues.
    public func notify(_ events: [HistoryEvent]) {
        guard !events.isEmpty else { return }
        pending.append(contentsOf: events)
        guard windowTask == nil else { return }
        windowID += 1
        let id = windowID
        windowTask = Task { [clock, window] in
            do {
                try await clock.sleep(for: window)
            } catch {
                return
            }
            await self.windowElapsed(id)
        }
    }

    /// Meldet alle wartenden Events sofort (z. B. beim Beenden) und schließt das Fenster.
    public func flushNow() async {
        windowTask?.cancel()
        await flush()
    }

    /// Eine gerade akzeptierte App soll auch aus dem noch nicht zugestellten Sammelfenster verschwinden.
    public func discardAppNotifications(for appIDs: Set<String>) {
        pending.removeAll {
            if case .installedApp(let app) = $0.event.subject { return appIDs.contains(app.id) }
            return false
        }
    }

    private func windowElapsed(_ id: Int) async {
        guard id == windowID else { return }
        await flush()
    }

    private func flush() async {
        let events = pending
        pending = []
        windowTask = nil
        windowID += 1
        guard !events.isEmpty else { return }

        if events.count > individualLimit {
            let summary = ChangeDescription.summary(for: events.map(\.event))
            await notifier.post(
                title: summary.title, body: summary.body,
                identifier: "summary-\(events[0].id.uuidString)", destination: .history
            )
        } else {
            for event in events {
                let description = ChangeDescription(event.event)
                await notifier.post(
                    title: description.title, body: description.body,
                    identifier: event.id.uuidString, destination: NotificationDestination(for: event.event)
                )
            }
        }
    }
}
