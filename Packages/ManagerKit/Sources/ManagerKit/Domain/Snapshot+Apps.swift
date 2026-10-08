import Foundation

extension Snapshot {
    /// Schreibt den Zustand installierter Apps aus `previous` fort (Plan v3, Entscheidungen; Review Task 1):
    /// - nicht prüfbare Signatur (`.unknown`), Architektur bzw. Herkunft (`.unverified`): der letzte bekannte Wert des
    ///   Vorgängers – wie
    ///   `lastKnownState` bei Sicherheitsprüfungen. So bleibt ein Team-ID-Wechsel erkennbar, auch wenn dazwischen ein
    ///   Snapshot mit ausgefallener Prüfung gespeichert wurde,
    /// - Team-ID-Wechsel (`InstalledApp.teamIDChange`): gilt ab `takenAt`, wenn sich die Team-ID gegenüber der letzten
    ///   bekannten unterscheidet (beide bekannt); sonst bleibt der bisherige Wechsel erhalten,
    /// - fortgeschriebene Signaturen sind als veraltet markiert (`SigningLimitation.carriedForward`, mit dem Zeitpunkt
    ///   der letzten echten Prüfung); hat sich das Hauptprogramm seitdem geändert (`executableFingerprint`), wird nichts
    ///   übernommen (`SigningLimitation.changedSinceCheck`) – ein Austausch bliebe sonst hinter der alten Signatur
    ///   verborgen (Review M2).
    ///
    /// Idempotent: Erneutes Anwenden mit demselben Vorgänger ändert nichts.
    func carryingForwardAppState(from previous: Snapshot?) -> Snapshot {
        guard let previous, !installedApps.isEmpty else { return self }
        let previousByID = previous.installedApps.firstByID()
        var result = self
        result.installedApps = installedApps.map {
            $0.carryingForward(from: previousByID[$0.id], scannedAt: previous.takenAt, at: takenAt)
        }
        return result
    }
}

extension Snapshot {
    /// Übernimmt aus `previous` die Apps, die in `folders` liegen (Pfad darunter) und in diesem Snapshot fehlen: Ein nicht
    /// lesbarer Ordner (`InventoryContribution.incompleteFolders`) belegt kein Entfernen (Review M3). Apps aus gelesenen
    /// Ordnern, die fehlen, gelten weiter als entfernt. Idempotent.
    func carryingForwardApps(inIncompleteFolders folders: [String], from previous: Snapshot?) -> Snapshot {
        guard let previous, !folders.isEmpty else { return self }
        let present = Set(installedApps.map(\.id))
        let prefixes = folders.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var result = self
        result.installedApps += previous.installedApps.filter { app in
            !present.contains(app.id) && prefixes.contains(where: app.path.hasPrefix)
        }
        return result
    }
}

extension InstalledApp {
    /// Diese App mit dem fortgeschriebenen Zustand aus `previous` (siehe `Snapshot.carryingForwardAppState`).
    /// - Parameter scannedAt: Zeitpunkt des Scans von `previous`.
    func carryingForward(from previous: InstalledApp?, scannedAt previousDate: Date, at date: Date) -> InstalledApp {
        // Ein Symlink-Bundle wird nie geprüft; es erbt nichts und vererbt nichts (Review M3).
        guard let previous, symlinkTarget == nil, previous.symlinkTarget == nil else { return self }
        var result = self
        if hasChangedExecutable(since: previous) {
            if signing.kind == .unknown, previous.signing.kind != .unknown || previous.signingLimitation == .changedSinceCheck {
                result.signingLimitation = .changedSinceCheck
            }
        } else {
            result.carryKnownValues(from: previous, scannedAt: previousDate)
        }

        let reference = previous.referenceTeamID
        if let old = reference, let new = result.signing.teamID, old != new {
            result.teamIDChange = TeamIDChange(previousTeamID: old, detectedAt: date)
        } else {
            result.teamIDChange = previous.teamIDChange
        }
        result.lastKnownTeamID = result.signing.teamID == nil ? reference : nil
        return result
    }

    /// `true`, wenn beide Fingerabdrücke des Hauptprogramms bekannt sind und sich unterscheiden (`matches`: Felder, die
    /// ein älterer Snapshot nicht kennt, zählen nicht).
    private func hasChangedExecutable(since previous: InstalledApp) -> Bool {
        guard let current = executableFingerprint, let old = previous.executableFingerprint else { return false }
        return !current.matches(old)
    }

    /// Übernimmt bei unverändertem Hauptprogramm die letzten bekannten Werte für nicht Prüfbares und markiert eine
    /// übernommene Signatur als veraltet.
    private mutating func carryKnownValues(from previous: InstalledApp, scannedAt previousDate: Date) {
        if let carried = signing.carryingKnownValues(from: previous.signing) {
            signing = carried
            signingLimitation = .carriedForward(verifiedAt: previous.signingVerifiedAt(scannedAt: previousDate))
        } else if signing.kind == .unknown, previous.signingLimitation == .changedSinceCheck {
            signingLimitation = .changedSinceCheck
        }
        if architecture == .unknown { architecture = previous.architecture }
        if origin == .unverified { origin = previous.origin }
    }

    /// Zeitpunkt der letzten echten Prüfung von `signing`, wenn diese App aus dem Scan von `scannedAt` stammt.
    private func signingVerifiedAt(scannedAt date: Date) -> Date {
        if case .carriedForward(let verifiedAt)? = signingLimitation { verifiedAt } else { date }
    }
}

extension SigningInfo {
    /// Bei nicht prüfbarer Signaturart die letzte bekannte Signatur – außer die Prüfung lieferte eine andere Team-ID:
    /// Die ist ein Beleg und bleibt (ein Wechsel wird so erkannt statt überschrieben). `nil`, wenn nichts übernommen wird.
    fileprivate func carryingKnownValues(from previous: SigningInfo) -> SigningInfo? {
        guard kind == .unknown, previous.kind != .unknown, teamID == nil || teamID == previous.teamID else { return nil }
        return previous
    }
}
