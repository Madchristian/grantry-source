import Foundation

/// Ein Wert einer Messreihe; `nil` heißt „nicht gemessen“ und ist eine Lücke, nie 0.
struct FindingSample: Hashable, Sendable {
    let time: Date
    let value: Double?
}

/// Ein Abschnitt, in dem eine Regel galt: von ihrem ersten bis zum letzten Punkt über der Schwelle.
struct FindingEpisode: Hashable, Sendable {
    let start: Date
    /// `nil`, solange die Ruhezeit noch nicht gemessen ist.
    let end: Date?
    let peak: Double
    let mean: Double
}

/// Hysterese einer Regel als reine Funktion über eine zeitlich geordnete Reihe:
/// - Beginn erst, wenn der Wert ohne Lücke `minimumDuration` lang über der Schwelle liegt; als Beginn zählt der erste
///   Punkt darüber.
/// - Ende erst nach `quietDuration` ohne Lücke unter der Schwelle; als Ende zählt der letzte Punkt darüber.
/// - Eine Lücke (nicht gemessener Punkt oder Abstand über `maximumGap`, etwa Ruhezustand) unterbricht beide Zählungen:
///   Sie startet und beendet keinen Befund.
struct FindingHysteresis {
    let rule: FindingRule
    let maximumGap: TimeInterval

    func episodes(in samples: [FindingSample]) -> [FindingEpisode] {
        var episodes: [FindingEpisode] = []
        var run: Run?
        var isOpen = false
        var quietSince: Date?
        var previous: Date?
        for sample in samples {
            guard let value = sample.value else {
                previous = nil
                continue
            }
            if previous.map({ sample.time.timeIntervalSince($0) > maximumGap }) ?? true {
                // Neuer lückenloser Abschnitt: Nur ein bereits begonnener Befund läuft weiter.
                if !isOpen { run = nil }
                quietSince = nil
            }
            previous = sample.time
            if value > rule.limit {
                quietSince = nil
                if run == nil { run = Run(start: sample.time) }
                run?.add(value, at: sample.time)
                if let start = run?.start, sample.time.timeIntervalSince(start) >= rule.minimumDuration {
                    isOpen = true
                }
            } else if isOpen, let current = run {
                let since = quietSince ?? sample.time
                quietSince = since
                if sample.time.timeIntervalSince(since) >= rule.quietDuration {
                    episodes.append(current.episode(ended: true))
                    (run, isOpen, quietSince) = (nil, false, nil)
                }
            } else {
                run = nil
            }
        }
        if isOpen, let run { episodes.append(run.episode(ended: false)) }
        return episodes
    }

    /// Punkte über der Schwelle seit ihrem ersten.
    private struct Run {
        let start: Date
        var last: Date
        var peak = -Double.infinity
        var sum = 0.0
        var count = 0

        init(start: Date) {
            self.start = start
            last = start
        }

        mutating func add(_ value: Double, at time: Date) {
            last = time
            peak = max(peak, value)
            sum += value
            count += 1
        }

        func episode(ended: Bool) -> FindingEpisode {
            FindingEpisode(start: start, end: ended ? last : nil, peak: peak, mean: sum / Double(max(count, 1)))
        }
    }
}
