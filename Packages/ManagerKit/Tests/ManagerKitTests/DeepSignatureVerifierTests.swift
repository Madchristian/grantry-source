import Foundation
import Synchronization
import Security
import Testing
@testable import ManagerKit
import TestSupport

/// Die echte Prüfung wartet blockierend auf Security.framework, das selbst Threads der globalen Dispatch-Queues braucht;
/// sie läuft daher auf eigenem Thread (`onOwnThread`), nie im kooperativen Pool.
@Suite struct SecuritySignatureValidatorTests {
    let validator = SecuritySignatureValidator()

    private func validate(_ path: String) async -> DeepSignatureVerdict {
        await onOwnThread { [validator] in validator.validate(path: path) }
    }

    @Test func intactAdHocBundleIsValid() async throws {
        try await ScratchDirectory.with(prefix: "deep-signature") { directory in
            let bundle = try Codesign.bundle(in: directory, named: "Intakt", adHoc: true, resources: ["config.txt": "x"])
            #expect(await validate(bundle.path) == .valid)
        }
    }

    /// Wie eine App, die in ihr eigenes Bundle schreibt: Die Basisprüfung (`SecuritySigningInspector`) sieht nichts,
    /// die vollständige Prüfung schon.
    @Test func bundleWithModifiedResourceIsInvalid() async throws {
        try await ScratchDirectory.with(prefix: "deep-signature") { directory in
            let bundle = try Codesign.tamperedBundle(in: directory, named: "Manipuliert")
            let path = bundle.path
            #expect(await onOwnThread { SecuritySigningInspector().inspect(path: path).kind } == .adHoc)
            #expect(await validate(path) == .invalid(status: errSecCSBadResource))
        }
    }

    @Test func unsignedAndMissingCodeIsUnverifiable() async throws {
        try await ScratchDirectory.with(prefix: "deep-signature") { directory in
            let binary = try Codesign.unsignedBinary(in: directory)
            #expect(await validate(binary.path) == .unverifiable)
            #expect(await validate(directory.appending(path: "fehlt").path) == .unverifiable)
        }
    }

    @Test func timeoutIsNotAVerdict() {
        #expect(DeepSignatureValidation.timedOut.verdict == .unverifiable)
        #expect(!DeepSignatureValidation.timedOut.isConclusive)
        #expect(DeepSignatureValidation.completed(.valid).verdict == .valid)
        #expect(DeepSignatureValidation.completed(.unverifiable).isConclusive)
    }

    @Test func onlyTamperingStatusesAreInvalid() {
        #expect(SecuritySignatureValidator.verdict(for: errSecSuccess) == .valid)
        #expect(SecuritySignatureValidator.verdict(for: errSecCSResourceDirectoryFailed)
            == .invalid(status: errSecCSResourceDirectoryFailed))
        #expect(SecuritySignatureValidator.verdict(for: errSecCSSignatureFailed) == .invalid(status: errSecCSSignatureFailed))
        #expect(SecuritySignatureValidator.verdict(for: errSecCSUnsigned) == .unverifiable)
        #expect(SecuritySignatureValidator.verdict(for: errSecCSStaticCodeNotFound) == .unverifiable)
    }

    /// Jeder Manipulations-Code hat einen Klartext (laut `CSCommon.h`), unbekannte Codes einen Rückfall mit Code.
    @Test func invalidVerdictsExplainTheirStatus() {
        #expect(DeepSignatureVerdict.invalid(status: errSecCSResourceDirectoryFailed).failureReason
            == "Ressourcen des Bundles verändert (Fehler -67023)")
        #expect(DeepSignatureVerdict.invalid(status: errSecCSBadResource).failureReason
            == "versiegelte Datei fehlt, wurde verändert oder hinzugefügt (Fehler -67054)")
        #expect(DeepSignatureVerdict.invalid(status: errSecCSSignatureFailed).failureReason
            == "Programm oder Signatur wurden verändert (Fehler -67061)")
        #expect(DeepSignatureVerdict.invalid(status: -1).failureReason == "unbekannter Fehler (Fehler -1)")
        #expect(DeepSignatureVerdict.valid.failureReason == nil)
        #expect(DeepSignatureVerdict.unverifiable.failureReason == nil)
        #expect(DeepSignatureVerdict.containsSpecialFiles.failureReason == nil)
        for status in SecuritySignatureValidator.tamperingStatuses {
            let reason = DeepSignatureVerdict.invalid(status: status).failureReason ?? ""
            #expect(!reason.hasPrefix("unbekannter Fehler"), "\(status)")
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DeepSignatureVerifierTests {
    /// `count` vorhandene Dateien im Verzeichnis – Ziele mit lesbarem Fingerabdruck.
    private func files(_ count: Int, in directory: URL) throws -> [String] {
        try (0..<count).map { index in
            let file = directory.appending(path: "app-\(index)")
            try Data("\(index)".utf8).write(to: file)
            return file.path
        }
    }

    @Test func tamperedBundleIsReportedInvalid() async throws {
        try await ScratchDirectory.with(prefix: "deep-verifier") { directory in
            let bundle = try Codesign.tamperedBundle(in: directory, named: "Manipuliert")
            #expect(await DeepSignatureVerifier().verify(path: bundle.path).isInvalid)
        }
    }

    @Test func verdictsAreCachedPerFingerprint() async throws {
        try await ScratchDirectory.with(prefix: "deep-verifier") { directory in
            let path = try files(1, in: directory)[0]
            let validator = ScriptedSignatureValidator(verdicts: [path: .invalid(status: errSecCSBadResource)])
            let verifier = DeepSignatureVerifier(validator: validator)

            #expect(await verifier.cachedVerdicts(for: [path]).isEmpty)
            #expect(await verifier.verify(path: path) == .invalid(status: errSecCSBadResource))
            #expect(await verifier.verify(path: path) == .invalid(status: errSecCSBadResource))
            #expect(await verifier.cachedVerdicts(for: [path]) == [path: .invalid(status: errSecCSBadResource)])
            #expect(validator.calls == [path])

            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: path)
            #expect(await verifier.cachedVerdicts(for: [path]).isEmpty, "neuer Fingerabdruck macht den Eintrag ungültig")
            _ = await verifier.verify(path: path)
            #expect(validator.calls == [path, path])
        }
    }

    /// Eine Zeitüberschreitung (oder ein erschöpfter Guard) ist kein Ergebnis: „nicht prüfbar“, nie im Cache (Review
    /// M1). Sie wird aber je Fingerabdruck `timeoutRetryDelay` lang gemerkt (Review N5) – sonst hinge jeder Scan erneut
    /// an derselben App; danach oder nach einer Änderung des Ziels wird wieder geprüft.
    @Test func timeoutsAreRememberedBrieflyButNotCached() async throws {
        try await ScratchDirectory.with(prefix: "deep-verifier") { directory in
            let path = try files(1, in: directory)[0]
            let validator = ScriptedSignatureValidator(verdicts: [path: .invalid(status: errSecCSBadResource)],
                                                       timeouts: [path, path])
            let clock = ManualClock()
            let verifier = DeepSignatureVerifier(validator: validator, now: { clock.now })

            #expect(await verifier.verify(path: path) == .unverifiable)
            #expect(await verifier.cachedVerdicts(for: [path]).isEmpty)
            clock.advance(by: DeepSignatureVerifier.timeoutRetryDelay - 1)
            #expect(await verifier.verify(path: path) == .unverifiable)
            #expect(validator.calls == [path], "innerhalb der Frist nicht erneut")

            clock.advance(by: 2)
            #expect(await verifier.verify(path: path) == .unverifiable, "zweite Zeitüberschreitung")
            #expect(validator.calls == [path, path])

            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: path)
            #expect(await verifier.verify(path: path) == .invalid(status: errSecCSBadResource), "geändertes Ziel sofort")
            #expect(await verifier.cachedVerdicts(for: [path]) == [path: .invalid(status: errSecCSBadResource)])
            #expect(validator.calls == [path, path, path])
        }
    }

    @Test func missingPathsAreNotValidated() async {
        let validator = ScriptedSignatureValidator()
        let verifier = DeepSignatureVerifier(validator: validator)
        #expect(await verifier.verify(path: "/does/not/exist.app") == .unverifiable)
        #expect(validator.calls.isEmpty)
    }

    /// Performance-Guard: gleichzeitige Anfragen – auch vom Main Actor – laufen nacheinander und nie auf dem Main Thread.
    @Test func checksNeverRunConcurrentlyOrOnTheMainThread() async throws {
        try await ScratchDirectory.with(prefix: "deep-verifier") { directory in
            let paths = try files(4, in: directory)
            let validator = ScriptedSignatureValidator(duration: 0.05)
            let verifier = DeepSignatureVerifier(validator: validator)

            let requests = paths.map { path in
                Task { @MainActor in _ = await verifier.verify(path: path) }
            }
            for request in requests {
                await request.value
            }

            #expect(Set(validator.calls) == Set(paths))
            #expect(validator.maxConcurrentChecks == 1)
            #expect(!validator.ranOnMainThread)
        }
    }

    /// Gleichzeitige Anfragen für denselben Pfad teilen sich eine laufende Prüfung.
    @Test func concurrentRequestsForTheSamePathShareOneCheck() async throws {
        try await ScratchDirectory.with(prefix: "deep-verifier") { directory in
            let path = try files(1, in: directory)[0]
            let validator = ScriptedSignatureValidator(verdicts: [path: .invalid(status: errSecCSBadResource)], holding: true)
            let verifier = DeepSignatureVerifier(validator: validator)

            var starts = validator.starts.makeAsyncIterator()
            let first = Task { await verifier.verify(path: path) }
            #expect(await starts.next() == path)
            let second = Task { await verifier.verify(path: path) }
            while await verifier.requestCount < 2 { await Task.yield() }

            validator.release()
            validator.release()   // gäbe eine zweite, doppelte Prüfung frei
            #expect(await first.value == .invalid(status: errSecCSBadResource))
            #expect(await second.value == .invalid(status: errSecCSBadResource))
            #expect(validator.calls == [path])
        }
    }

    /// Eine minutenlange Prüfung blockiert weder den Actor noch Cache-Abfragen.
    @Test func cacheLookupsAnswerWhileACheckRuns() async throws {
        try await ScratchDirectory.with(prefix: "deep-verifier") { directory in
            let paths = try files(2, in: directory)
            let validator = ScriptedSignatureValidator(holding: true)
            let verifier = DeepSignatureVerifier(validator: validator)
            validator.release()
            _ = await verifier.verify(path: paths[0])

            var starts = validator.starts.makeAsyncIterator()
            _ = await starts.next()
            let running = Task { await verifier.verify(path: paths[1]) }
            #expect(await starts.next() == paths[1])

            #expect(await verifier.cachedVerdicts(for: paths) == [paths[0]: .valid])
            validator.release()
            #expect(await running.value == .valid)
        }
    }
}
