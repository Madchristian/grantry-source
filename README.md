# Grantry – Quellcode zur Einsicht

Grantry ist eine kostenlose macOS-App zur Übersicht und Verwaltung von Systemzustand,
Autostart-Einträgen, installierter Software, Netzwerkdiensten und Agenten-/MCP-Konfigurationen.
Dieses Repository macht das Verhalten der veröffentlichten App nachvollziehbar.

**Quellstand: 2026.10.81 · Build 739**

Die offizielle App und weitere Informationen gibt es auf [grantry.cstrube.de](https://grantry.cstrube.de).

## Orientierung im Quellcode

| Verzeichnis | Inhalt |
|---|---|
| `Grantry/` | Oberfläche und App-Verhalten |
| `GrantryHelper/` und `Packages/ManagerKit/Sources/HelperCore/` | Privilegierter Helper für die vorgesehenen Systemaktionen |
| `Packages/ManagerKit/Sources/ManagerKit/` | Datenerfassung, Fachlogik, Aktionen und Schutzmechanismen |
| `Packages/ManagerKit/Tests/` | Tests und Testdaten |
| `Packages/ManagerKit/Sources/GrantryShared/` | Gemeinsame Typen und Schnittstellen von App und Helper |

[SOURCE.json](SOURCE.json) ordnet die Dateien dem ursprünglichen Release-Quellcommit zu
und enthält ihre SHA-256-Prüfsummen sowie die Prüfsumme des offiziellen DMG.
Die darin aufgeführten Quelldateien sind unverändert aus diesem Stand übernommen.
Testdaten können ausdrücklich künstliche Token und Beispielkonfigurationen enthalten.

Veröffentlicht werden ausgewählte Quellcode- und Ressourcendateien zur Einsicht.
Interne Entwicklungsunterlagen, Agenten-Anweisungen, Build-/Release-Anleitungen,
Signierungs- und Veröffentlichungswerkzeuge sind nicht Bestandteil dieses Repositorys.

## Lizenz

Es gilt die [Grantry-Lizenz](LICENSE.md). Alle Rechte vorbehalten.
Die Veröffentlichung zur Einsicht ist keine Freigabe unter einer Open-Source-Lizenz.
