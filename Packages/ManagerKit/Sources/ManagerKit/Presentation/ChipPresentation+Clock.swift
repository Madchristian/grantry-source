import Foundation

extension ChipPage {
    /// Panel „Takt und Thermik“ (TM-14.3): Peilkopf mit Cache und Kernen je Cluster, je Cluster ein Taktband aus der
    /// Taktverteilung der letzten 60 s, darunter der thermische Zustand über die Zeit. Drosselung als Grund-Satz.
    public struct Clock: Hashable, Sendable {
        /// Eine Taktstufe: Takt in GHz, Zeitanteil, Hitze relativ zur häufigsten Stufe des Clusters.
        public struct Step: Hashable, Sendable {
            public let frequencyMHz: Double
            public let frequency: String
            public let share: String
            public let heat: Double
        }

        /// Taktband eines Clusters; ohne Stufen steht `placeholder` an seiner Stelle.
        public struct Band: Hashable, Sendable, Identifiable {
            public let id: String
            public let title: String
            public let kind: CoreKind
            /// Häufigste Stufe.
            public let value: String
            /// Anteil Höchsttakt bzw. Zahl der Cluster ohne Helper.
            public let detail: String
            public let steps: [Step]
            public let placeholder: String
            public let accessibilityValue: String
        }

        /// Abschnitt gleichen thermischen Zustands als Anteil des Zeitraums (0 = vor `window`, 1 = jetzt).
        public struct ThermalSegment: Hashable, Sendable {
            public let start: Double
            public let end: Double
            public let state: ProcessInfo.ThermalState
            public let title: String
        }

        public let title: String
        public let detail: String
        /// Mittlerer Takt der Leistungscluster, gewichtet mit ihrer aktiven Zeit.
        public let value: String
        /// `value` als Anteil am Höchsttakt.
        public let fraction: Double?
        /// Grund eines laufenden Befunds „Drosselung“.
        public let finding: String?
        public let caption: String
        public let bands: [Band]
        public let thermalTitle: String
        /// `nil`, solange kein Stand bekannt ist.
        public let thermalState: ProcessInfo.ThermalState?
        public let thermalCurrent: String
        /// Feinere Stufe des Samplers `thermal`; leer ohne Helper.
        public let thermalDetail: String
        public let thermalSegments: [ThermalSegment]
        public let window: TimeInterval
        public let thermalAccessibilityValue: String
    }
}

extension ChipPresentation {
    /// Stufen unter diesem Anteil zeigen „–“ statt „0 %“.
    static let visibleShare = 0.005

    /// - Parameters:
    ///   - sensors: letzte Messung des Helpers; `nil` ohne Helper – dann eine Zeile „Ohne Helper nicht messbar“.
    ///   - distribution: Taktverteilung der letzten 60 s (`SensorModel.clockHistory`).
    ///   - thermal: Verlauf von `ThermalStateSource`; `now` ist das Ende des Thermikbands.
    public static func clock(profile: ChipProfile, sensors: SensorReading?, distribution: ClockDistributionHistory,
                             thermal: ThermalStateHistory, now: Date, findings: [SystemFinding]) -> ChipPage.Clock {
        let head = clockHead(sensors)
        let current = thermal.condition(at: now)?.state
        let segments = thermalSegments(thermal, now: now)
        return ChipPage.Clock(
            title: "Takt und Thermik",
            detail: profile.levels.indices.map { index in
                "\(profile.kind(ofLevel: index).title): "
                    + detailParts(of: profile.levels[index]).joined(separator: ", ")
            }.joined(separator: " · "),
            value: head.map { gigahertz($0.megahertz) + " GHz" } ?? missing,
            fraction: head?.fraction,
            finding: findings.first { $0.kind == .throttling && $0.end == nil }?.reason,
            caption: "Anteil der aktiven Zeit je Taktstufe, letzte \(Int(ClockDistributionHistory.span)) Sekunden",
            bands: sensors.map { bands(profile, sensors: $0, distribution: distribution) }
                ?? [unmeasuredBand(clusters: profile.levels.reduce(0) { $0 + $1.clusters.count })],
            thermalTitle: "Thermik",
            thermalState: current,
            thermalCurrent: current.map(PerformancePresentation.thermalText) ?? missing,
            thermalDetail: sensors?.thermalPressure.flatMap(ThermalPressureLevel.init).map { "Druck: \($0.text)" } ?? "",
            thermalSegments: segments,
            window: thermal.span,
            thermalAccessibilityValue: "letzte \(Int(thermal.span / 60)) Minuten: "
                + (segments.isEmpty ? "nicht gemessen" : segments.map(\.title).joined(separator: ", dann "))
        )
    }

    /// Mittlerer Takt der Leistungscluster (gewichtet mit der aktiven Zeit, ohne sie ungewichtet) und sein Anteil am
    /// Höchsttakt.
    static func clockHead(_ sensors: SensorReading?) -> (megahertz: Double, fraction: Double?)? {
        let clusters = (sensors?.clusters ?? []).filter { !$0.isEfficiency && $0.frequencyMHz != nil }
        guard !clusters.isEmpty else { return nil }
        let weights = clusters.map { max($0.activeShare ?? 0, 0) }
        let total = weights.reduce(0, +)
        let megahertz = zip(clusters, weights).reduce(0) { sum, pair in
            sum + (pair.0.frequencyMHz ?? 0) * (total > 0 ? pair.1 / total : 1 / Double(clusters.count))
        }
        let maximum = clusters.compactMap(\.maximumFrequencyMHz).max()
        return (megahertz, maximum.flatMap { $0 > 0 ? min(megahertz / $0, 1) : nil })
    }

    private static func bands(_ profile: ChipProfile, sensors: SensorReading,
                              distribution: ClockDistributionHistory) -> [ChipPage.Clock.Band] {
        profile.levels.indices.flatMap { index in
            let level = profile.levels[index]
            return level.clusters.map { cluster in
                let title = cluster.label.map { "Cluster \($0)" } ?? profile.kind(ofLevel: index).title
                let steps = sensorCluster(for: cluster, in: sensors).map { distribution.steps(ofCluster: $0.name) } ?? []
                return band(id: cluster.label ?? "\(index)", title: title, kind: profile.kind(ofLevel: index),
                            steps: steps)
            }
        }
    }

    static func band(id: String, title: String, kind: CoreKind, steps: [SensorReading.FrequencyStep])
        -> ChipPage.Clock.Band {
        guard let mostFrequent = steps.max(by: { ($0.share, $0.frequencyMHz) < ($1.share, $1.frequencyMHz) }),
              let highest = steps.last, mostFrequent.share > 0 else {
            return ChipPage.Clock.Band(id: id, title: title, kind: kind, value: missing, detail: "", steps: [],
                                       placeholder: "Im Messzeitraum nicht aktiv",
                                       accessibilityValue: "im Messzeitraum nicht aktiv")
        }
        let top = PerformancePresentation.percent(highest.share)
        let frequent = gigahertz(mostFrequent.frequencyMHz)
        return ChipPage.Clock.Band(
            id: id, title: title, kind: kind, value: "meist \(frequent) GHz", detail: "Höchsttakt \(top)",
            steps: steps.map { step in
                ChipPage.Clock.Step(frequencyMHz: step.frequencyMHz, frequency: gigahertz(step.frequencyMHz),
                                    share: step.share < visibleShare ? missing : PerformancePresentation.percent(step.share),
                                    heat: step.share / mostFrequent.share)
            },
            placeholder: "", accessibilityValue: "häufigste Stufe \(frequent) GHz, Höchsttakt \(top)")
    }

    private static func unmeasuredBand(clusters: Int) -> ChipPage.Clock.Band {
        ChipPage.Clock.Band(id: "unmeasured", title: "Taktstufen", kind: .unknown, value: missing,
                            detail: clusters == 1 ? "1 Cluster" : "\(clusters) Cluster", steps: [],
                            placeholder: "Ohne Helper nicht messbar", accessibilityValue: "ohne Helper nicht messbar")
    }

    /// Abschnitte im Zeitraum; Wechsel nur des Energiesparmodus ergeben keinen neuen Abschnitt.
    private static func thermalSegments(_ history: ThermalStateHistory, now: Date) -> [ChipPage.Clock.ThermalSegment] {
        let start = now.addingTimeInterval(-history.span)
        let fraction = { (time: Date) in min(max(time.timeIntervalSince(start) / history.span, 0), 1) }
        var segments: [ChipPage.Clock.ThermalSegment] = []
        for segment in history.segments(from: start, to: now) {
            let state = segment.condition.state
            if let last = segments.last, last.state == state, last.end == fraction(segment.start) {
                segments[segments.count - 1] = ChipPage.Clock.ThermalSegment(
                    start: last.start, end: fraction(segment.end), state: state, title: last.title)
            } else {
                segments.append(ChipPage.Clock.ThermalSegment(
                    start: fraction(segment.start), end: fraction(segment.end), state: state,
                    title: PerformancePresentation.thermalText(state)))
            }
        }
        return segments
    }

    /// „4,51“ – zwei Nachkommastellen, damit dicht liegende Stufen (3,95 und 3,99 GHz) unterscheidbar bleiben.
    static func gigahertz(_ megahertz: Double) -> String {
        (megahertz / 1000).formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "de_DE")))
    }
}

extension ThermalPressureLevel {
    /// Stufe des Samplers `thermal` in Worten.
    var text: String {
        switch self {
        case .nominal: "nominal"
        case .light: "leicht"
        case .moderate: "mäßig"
        case .heavy: "stark"
        case .critical: "kritisch"
        }
    }
}
