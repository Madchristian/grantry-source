import Foundation
import Testing
@testable import ManagerKit

/// Penetrationstests (Audit 2026-10-09, Befund C1): `ShellSyntax.scriptIndices` kopierte für jedes Wort eines
/// Arguments mit Leerraum die gesamte restliche Argumentliste (`Array(words.dropFirst(…)) + arguments.dropFirst(…)`) –
/// quadratisch in der Zahl der Argumente. Eine präparierte `.mcp.json` in einem geklonten Repo (`"args": ["a b", …]`,
/// bis zur 5-MB-Grenze rund 800 000 Einträge) hielt die serielle Agenten-Queue auf einem Kern fest; derselbe Weg
/// läuft beim Laden jedes Snapshots und in der Anzeige erneut. Obergrenze und kopierfreie Auswertung schützen beide.
///
/// Der damalige Test `manyOrdinaryArgumentsRemainReadableWithoutQuadraticCopies` nutzte Argumente ohne Leerraum
/// und erreichte den Zweig nicht.
@Suite(.timeLimit(.minutes(2))) struct PenetrationCommandRedactionLoadTests {
    /// Rein textuell (`resolvingPath: { _ in nil }`), damit nur die Laufzeit der Heuristik zählt.
    private func elapsed(redacting arguments: [String]) -> Duration {
        // Nach dem frühen Abbruch dauert ein Aufruf nur Mikrosekunden: den Median gegen Scheduler-Ausreißer nutzen.
        let measurements = (0..<7).map { _ in
            ContinuousClock().measure { _ = ArgumentRedactor.redact(arguments: arguments, resolvingPath: { _ in nil }) }
        }.sorted()
        return measurements[measurements.count / 2]
    }

    /// Dieselbe Liste mit Leerraum darf nicht wesentlich länger brauchen als ohne – gemessen gegeneinander, damit die
    /// Geschwindigkeit des Rechners herausfällt (vor dem Fix rund das 3,5-Fache; bei 800 000 Einträgen Stunden).
    @Test func argumentsWithWhitespaceCostAboutAsMuchAsOrdinaryOnes() {
        let ordinary = elapsed(redacting: ["tool"] + Array(repeating: "ab", count: 20_000))
        let whitespace = elapsed(redacting: ["tool"] + Array(repeating: "a b", count: 20_000))
        print("C1: ohne Leerraum \(ordinary), mit Leerraum \(whitespace)")
        #expect(whitespace < ordinary * 2, "ohne Leerraum \(ordinary), mit Leerraum \(whitespace)")
    }

    /// Die Argumentgrenze des Redactors darf quadratische Kopien im Scanner nicht nur verdecken.
    /// Sechzehnfache Eingabe: maximal das 24-Fache mit Reserve für Schwankungen, nicht quadratisch das 256-Fache.
    @Test func scriptDetectionScalesWithoutCopyingArgumentSuffixes() {
        func scan(_ count: Int) -> Duration {
            let arguments = ["tool"] + Array(repeating: "a b", count: count)
            return ContinuousClock().measure {
                #expect(ShellSyntax.scriptIndices(in: arguments, resolvingPath: { _ in nil }).isEmpty)
            }
        }
        _ = scan(100)
        let small = scan(4_000)
        let large = scan(64_000)
        print("C1 Scanner: 4000 \(small), 64000 \(large)")
        #expect(large < small * 24, "4000 Argumente \(small), 64000 Argumente \(large)")
    }

    @Test func excessiveArgumentsAreHiddenWithoutResolvingPaths() {
        let arguments = ["tool"] + Array(repeating: "a b", count: 4_096)
        var resolvedPaths = 0
        let result = ArgumentRedactor.redact(arguments: arguments, resolvingPath: { _ in
            resolvedPaths += 1
            return nil
        })
        #expect(resolvedPaths == 0)
        #expect(result.values.allSatisfy { $0 == ArgumentRedactor.mask })
        #expect(result.values.count == arguments.count)
        #expect(result.hasHiddenScript)
        #expect(ShellSyntax.hasHiddenScript(in: result.values, program: "tool"))
        // Ungeprüft ist kein Nachweis eines Klartext-Geheimnisses (wie bei der bestehenden Tiefengrenze).
        #expect(!result.containsSecret)
        #expect(MaskedCommandNote.text(for: result.values, program: "tool", isMasked: true,
                                       hasHiddenScript: result.hasHiddenScript) == MaskedCommandNote.hiddenScript)
        for classified in [false, true] {
            #expect(ArgumentRedactor.redactStored(arguments: arguments, hasScriptClassification: classified) == result)
        }
    }
}
