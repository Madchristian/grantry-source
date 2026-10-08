import Foundation

/// Erkennt die `PackageSource` eines lokalen Servers. Reine Funktion; unbekannte Formen ergeben `.command` (bzw.
/// `.localProgram`, wenn der Befehl ein absoluter Pfad ist – er muss in Signatur- und Ortsprüfung auftauchen).
///
/// Bekannte Grenzen (bewusst keine weitere Heuristik):
/// - Shell-Wrapper (`bash -c "npx …"`) und Runner, die ein anderes Programm starten (`npx tsx server.ts`): erkannt wird
///   nur der Befehl bzw. das erste Paket.
/// - Globale Optionen vor dem Unterkommando (`pnpm --silent dlx pkg`, `uv --quiet tool run pkg`) werden nicht
///   übersprungen; das Ergebnis ist `.command`.
/// - Unbekannte `docker`/`podman`-Optionen mit Wert als eigenem Argument: der Wert gilt als Image, außer er beginnt mit
///   `/` oder `.`.
/// - Wird `--package`/`-p` (npm) bzw. `--from`/`--spec` (PyPI) mehrfach angegeben, gilt die erste.
/// - Versionen: npm behält den Spezifizierer wie angegeben (`latest`, `^1`), PyPI nur eine exakte Festlegung.
/// - Git-Angaben gelten nur mit 40-stelligem Commit-Hash (`#…` bzw. `@…`) als festgelegt; Branch und Tag nicht.
/// - deno: `npm:`-Angaben zählen als npm; `jsr:` und `https://…` werden nicht aufgelöst (`.command(name: "deno")`).
public enum PackageSourceDetector {
    public static func detect(command: String, arguments: [String]) -> PackageSource {
        // Relative Pfade (`./bin/server`, `~/bin/server`) hängen vom Arbeitsverzeichnis ab: voller Text, keine Auswertung.
        if !command.hasPrefix("/"), command.contains("/") { return .command(name: command) }
        let name = command.split(separator: "/").last.map(String.init) ?? command
        switch name {
        case "env":
            if let wrapped = unwrapEnvironment(arguments) {
                return detect(command: wrapped.command, arguments: wrapped.arguments)
            }
            return program(command: command, name: name)
        case "npx", "bunx", "pnpx":
            return npm(arguments[...]) ?? program(command: command, name: name)
        // `where` gilt in Swift nur für das Muster davor – daher je Muster.
        case "pnpm" where arguments.first == "dlx", "yarn" where arguments.first == "dlx":
            return npm(arguments.dropFirst()) ?? program(command: command, name: name)
        case "bun" where arguments.first == "x":
            return npm(arguments.dropFirst()) ?? program(command: command, name: name)
        case "npm" where ["exec", "x"].contains(arguments.first):
            return npm(arguments.dropFirst()) ?? program(command: command, name: name)
        case "uvx":
            return pypi(arguments[...], specOption: "--from") ?? program(command: command, name: name)
        case "uv" where arguments.starts(with: ["tool", "run"]):
            return pypi(arguments.dropFirst(2), specOption: "--from") ?? program(command: command, name: name)
        case "pipx" where arguments.first == "run":
            return pypi(arguments.dropFirst(), specOption: "--spec") ?? program(command: command, name: name)
        case "docker", "podman":
            return container(arguments[...]) ?? program(command: command, name: name)
        default:
            if isInterpreter(name), let source = interpreterSource(name: name, arguments[...]) { return source }
            return program(command: command, name: name)
        }
    }

    /// Weder Runner noch Interpreter mit Skript: ein absoluter Pfad ist das Programm, sonst bleibt der Befehlsname.
    private static func program(command: String, name: String) -> PackageSource {
        command.hasPrefix("/") ? .localProgram(path: command) : .command(name: name)
    }

    // MARK: env

    /// Optionen von `env` mit Wert als eigenem Argument.
    private static let environmentOptionsWithValue: Set<String> = ["-u", "--unset", "-C", "--chdir", "-P", "-a", "--argv0"]

    /// `env [Optionen] [NAME=wert …] befehl args…` → (`befehl`, `args…`). `nil` ohne Befehl oder bei `-S`
    /// (nimmt den Rest als einen String, den Grantry nicht zerlegt).
    private static func unwrapEnvironment(_ arguments: [String]) -> (command: String, arguments: [String])? {
        var rest = arguments[...]
        while let argument = rest.first {
            if argument.hasPrefix("-S") || argument.hasPrefix("--split-string") { return nil }
            rest = rest.dropFirst()
            if environmentOptionsWithValue.contains(argument) {
                rest = rest.dropFirst()
            } else if !argument.hasPrefix("-"), !argument.contains("=") {
                return (argument, Array(rest))
            }
        }
        return nil
    }

    // MARK: npm

    /// Optionen von `npx`/`npm exec`/`pnpm dlx`/`yarn dlx` mit Wert als eigenem Argument (ohne `--package`).
    private static let npmOptionsWithValue: Set<String> = [
        "--registry", "--cache", "--userconfig", "--globalconfig", "--prefix", "--workspace", "-w", "--node-options",
        "--loglevel",
    ]

    private static func npm(_ arguments: ArraySlice<String>) -> PackageSource? {
        guard let scan = firstOperand(
            in: arguments, optionsWithValue: npmOptionsWithValue, capturing: ["-p", "--package"], aborting: ["-c", "--call"]
        ) else { return nil }
        return (scan.captured.first ?? scan.operand).flatMap(npmSource)
    }

    /// `@scope/name@1.0` → (`@scope/name`, `1.0`); `name` → (`name`, `nil`); Pfad, Git und URL siehe `directSource`;
    /// leer → `nil`.
    private static func npmSource(_ spec: String) -> PackageSource? {
        if let direct = directSource(spec, package: { .npm(package: $0, version: $1) }) { return direct }
        guard let at = spec.lastIndex(of: "@"), at > spec.startIndex else {
            return nonEmpty(spec).map { .npm(package: $0, version: nil) }
        }
        return .npm(package: String(spec[..<at]), version: nonEmpty(String(spec[spec.index(after: at)...])))
    }

    // MARK: PyPI

    /// Optionen von `uvx`/`uv tool run`/`pipx run` mit Wert als eigenem Argument (ohne `--from`/`--spec`).
    private static let pypiOptionsWithValue: Set<String> = [
        "--with", "-w", "--python", "-p", "--index-url", "--extra-index-url", "--index", "--pip-args", "--suffix",
        "--with-requirements", "--with-editable", "-c", "--constraint", "--overrides", "-f", "--find-links",
        "--default-index", "--index-strategy", "--keyring-provider", "--python-preference", "--cache-dir",
        "--config-file", "--exclude-newer", "--resolution", "--prerelease", "--refresh-package", "-P",
        "--upgrade-package", "--reinstall-package", "--env-file", "--directory", "--project",
    ]

    private static func pypi(_ arguments: ArraySlice<String>, specOption: String) -> PackageSource? {
        guard let scan = firstOperand(in: arguments, optionsWithValue: pypiOptionsWithValue, capturing: [specOption])
        else { return nil }
        return (scan.captured.first ?? scan.operand).flatMap(pypiSource)
    }

    /// `pkg[extra]==1.0` → (`pkg`, `1.0`); `pkg@1.0` → (`pkg`, `1.0`); `pkg>=1` und `pkg@latest` → (`pkg`, `nil`);
    /// `name @ url` (PEP 508) → (`name`, Commit-Hash der URL), bei `file:`-URL wie ein Pfad; Pfad, Git und URL siehe
    /// `directSource`; ohne Namen → `nil`.
    private static func pypiSource(_ rawSpec: String) -> PackageSource? {
        // Umgebungsmarker (`; python_version < "3.13"`) gehören nicht zum Paket.
        let spec = trimmed(rawSpec.prefix { $0 != ";" })
        if let range = spec.range(of: " @ ") {
            let location = trimmed(spec[range.upperBound...])
            if let local = localPathSource(location) { return local }
            return pypiName(spec[..<range.lowerBound]).map { .pypi(package: $0, version: splitCommit(location).commit) }
        }
        if let direct = directSource(spec, package: { .pypi(package: $0, version: $1) }) { return direct }
        for separator in ["===", "==", "@"] {
            guard let range = spec.range(of: separator) else { continue }
            let version = nonEmpty(trimmed(spec[range.upperBound...])).flatMap { $0 == "latest" ? nil : $0 }
            return pypiName(spec[..<range.lowerBound]).map { .pypi(package: $0, version: version) }
        }
        return pypiName(spec.prefix { !"<>=!~".contains($0) }).map { .pypi(package: $0, version: nil) }
    }

    /// Paketname ohne Extras (`pkg[cli]` → `pkg`).
    private static func pypiName(_ text: Substring) -> String? {
        nonEmpty(trimmed(text.prefix { $0 != "[" }))
    }

    // MARK: Container

    /// Globale Optionen von `docker`/`podman` vor dem Unterkommando mit Wert als eigenem Argument.
    private static let containerGlobalOptionsWithValue: Set<String> = [
        "--context", "-c", "-H", "--host", "--config", "--log-level", "-l", "--tlscacert", "--tlscert", "--tlskey",
        "--url", "--connection", "--identity", "--root", "--runroot", "--storage-driver",
    ]
    /// Optionen von `docker run`/`podman run` mit Wert als eigenem Argument.
    private static let containerRunOptionsWithValue: Set<String> = [
        "-e", "--env", "--env-file", "-v", "--volume", "--mount", "--name", "-p", "--publish", "--network", "--net",
        "-w", "--workdir", "-u", "--user", "--entrypoint", "-l", "--label", "--platform", "--add-host", "--cap-add",
        "--cap-drop", "--device", "-m", "--memory", "--cpus", "--pull", "--restart", "-h", "--hostname", "--ipc",
        "--pid", "--security-opt", "--tmpfs", "--ulimit", "--log-driver", "--log-opt", "--runtime", "--shm-size",
        "--dns", "--expose", "--gpus", "--group-add", "--label-file", "--mac-address", "--stop-signal", "--stop-timeout",
        "-a", "--attach", "--cidfile", "-c", "--cpu-shares", "--cpuset-cpus", "--memory-swap", "--cgroup-parent",
        "--cgroupns", "--userns", "--uts", "--volumes-from", "--link", "--sysctl", "--ip", "--ip6", "--network-alias",
        "--dns-search", "--dns-option", "--domainname", "--health-cmd", "--health-interval", "--health-retries",
        "--health-timeout", "--health-start-period", "--pids-limit", "--oom-score-adj", "--detach-keys",
        "--storage-opt", "--annotation", "--isolation", "--blkio-weight", "--pod", "--arch", "--os", "--variant",
        "--secret", "--cpu-period", "--cpu-quota", "--cpuset-mems", "--memory-reservation", "--memory-swappiness",
        "--kernel-memory", "--device-cgroup-rule", "--link-local-ip", "--blkio-weight-device", "--health-start-interval",
        "--pidfile",
    ]

    /// `docker [global] run|container run [Optionen] IMAGE …` → Image. Ein Kandidat, der mit `/` oder `.` beginnt, ist nie
    /// ein Image (Wert einer unbekannten Option) – die Suche geht weiter.
    private static func container(_ arguments: ArraySlice<String>) -> PackageSource? {
        guard var subcommand = firstOperand(in: arguments, optionsWithValue: containerGlobalOptionsWithValue)
        else { return nil }
        if subcommand.operand == "container" {
            guard let inner = firstOperand(in: subcommand.rest, optionsWithValue: containerGlobalOptionsWithValue)
            else { return nil }
            subcommand = inner
        }
        guard subcommand.operand == "run" else { return nil }
        var rest = subcommand.rest
        while let scan = firstOperand(in: rest, optionsWithValue: containerRunOptionsWithValue), let candidate = scan.operand {
            if candidate.hasPrefix("/") || candidate.hasPrefix(".") {
                rest = scan.rest
                continue
            }
            return containerImage(candidate)
        }
        return nil
    }

    /// `registry:5000/name:tag` → (`registry:5000/name`, `tag`); `name@sha256:…` und `name:tag@sha256:…` →
    /// (`name`, `sha256:…`); `name:` und `name@` → (`name`, `nil`); ohne Namen → `nil`.
    private static func containerImage(_ reference: String) -> PackageSource? {
        let (image, tag) = splitImageReference(reference)
        return nonEmpty(image).map { .container(image: $0, reference: nonEmpty(tag)) }
    }

    /// Trennt Image-Name und Tag/Digest. Der Digest hinter `@` hat Vorrang (ein zusätzlicher Tag fällt weg).
    private static func splitImageReference(_ reference: String) -> (image: String, tag: String) {
        guard let at = reference.firstIndex(of: "@") else { return splitTag(reference) }
        return (splitTag(String(reference[..<at])).image, String(reference[reference.index(after: at)...]))
    }

    /// Der Tag-Doppelpunkt zählt nur hinter dem letzten `/` (ein Registry-Port bleibt im Namen).
    private static func splitTag(_ name: String) -> (image: String, tag: String) {
        let lastSlash = name.lastIndex(of: "/") ?? name.startIndex
        guard let colon = name[lastSlash...].lastIndex(of: ":") else { return (name, "") }
        return (String(name[..<colon]), String(name[name.index(after: colon)...]))
    }

    // MARK: Interpreter

    /// Interpreter, deren erstes Nicht-Options-Argument ein Skript ist (zusätzlich `python3.12` & Co., siehe `isInterpreter`).
    private static let interpreters: Set<String> = [
        "node", "python", "python3", "bun", "deno", "ruby", "perl", "sh", "bash", "zsh", "php",
    ]

    /// Kommandozeilen-Optionen eines Interpreters. Alle übrigen `-x` sind Schalter ohne Wert und werden übersprungen.
    private struct InterpreterOptions {
        /// Optionen mit Wert als eigenem Argument.
        var withValue: Set<String>
        /// Optionen, nach denen kein Skript folgt (`python -m modul`, `node -e code`, `bash -c befehl`).
        var ending: Set<String>
    }

    private static let nodeOptions = InterpreterOptions(
        withValue: [
            "-r", "--require", "--import", "--loader", "--experimental-loader", "--env-file", "-C", "--conditions", "--title",
        ],
        ending: ["-e", "--eval", "-p", "--print", "-c", "--check"]
    )
    private static let denoOptions = InterpreterOptions(
        withValue: ["--config", "-c", "--import-map", "--env-file", "--location"],
        ending: ["-e", "--eval", "-p", "--print"]
    )
    private static let pythonOptions = InterpreterOptions(withValue: ["-X", "-W"], ending: ["-m", "-c"])
    private static let shellOptions = InterpreterOptions(
        withValue: ["-o", "-O", "--rcfile", "--init-file"], ending: ["-c", "-s"]
    )
    private static let perlRubyOptions = InterpreterOptions(withValue: ["-I", "-r"], ending: ["-e", "-E"])
    private static let phpOptions = InterpreterOptions(withValue: ["-d", "-c"], ending: ["-r"])

    private static func interpreterOptions(for name: String) -> InterpreterOptions {
        switch name {
        case "node", "bun": nodeOptions
        case "deno": denoOptions
        case "sh", "bash", "zsh": shellOptions
        case "perl", "ruby": perlRubyOptions
        case "php": phpOptions
        default: pythonOptions // python, python3, python3.12 …
        }
    }

    /// Bekannter Interpreter, auch mit Versionssuffix (`python3.12`, `python2`).
    private static func isInterpreter(_ name: String) -> Bool {
        interpreters.contains(name) || name.wholeMatch(of: /python[0-9]+(\.[0-9]+)?/) != nil
    }

    /// Absolutes Skript des Interpreters; bei `deno run npm:…` das npm-Paket. `nil` bei `-m`/`-c`/`-e`, relativem Skript,
    /// `jsr:`, `https://…` oder ohne Skript.
    private static func interpreterSource(name: String, _ arguments: ArraySlice<String>) -> PackageSource? {
        let options = interpreterOptions(for: name)
        guard var scan = firstOperand(in: arguments, optionsWithValue: options.withValue, aborting: options.ending)
        else { return nil }
        if scan.operand == "run" { // `deno run`, `bun run`
            guard let inner = firstOperand(in: scan.rest, optionsWithValue: options.withValue, aborting: options.ending)
            else { return nil }
            scan = inner
        }
        guard let operand = scan.operand else { return nil }
        if name == "deno", operand.hasPrefix("npm:") { return npmSource(String(operand.dropFirst("npm:".count))) }
        return operand.hasPrefix("/") ? .localProgram(path: operand) : nil
    }

    // MARK: Pfad-, Git- und URL-Angaben

    /// Präfixe von Git-/URL-Angaben, die kein Registry-Name sind (zusätzlich alles mit `://`).
    private static let remoteSpecPrefixes = ["git+", "github:", "gitlab:", "bitbucket:", "gist:"]

    /// Pfad-, Git- und URL-Angaben statt eines Registry-Namens: Pfade siehe `localPathSource`, Git/URL das ganze Paket
    /// ohne Versions-Split, festgelegt nur durch einen Commit-Hash. `nil` bei einem normalen Namen.
    private static func directSource(
        _ spec: String, package: (_ location: String, _ commit: String?) -> PackageSource
    ) -> PackageSource? {
        if let local = localPathSource(spec) { return local }
        guard spec.contains("://") || remoteSpecPrefixes.contains(where: { spec.hasPrefix($0) }) else { return nil }
        let (location, commit) = splitCommit(spec)
        return package(location, commit)
    }

    /// Lokale Pfadangabe (`/abs`, `file:///abs`, `file:/abs`, `./x`, `../x`, `~/x`, `.`): ein absoluter Pfad ist ein lokales
    /// Programm, ein relativer hängt vom Arbeitsverzeichnis ab und bleibt `.command` mit dem Pfadtext (wie ein relativer
    /// Befehl). `nil` bei Namen und URLs.
    private static func localPathSource(_ spec: String) -> PackageSource? {
        var path = spec
        if spec.hasPrefix("file:") {
            path = String(spec.hasPrefix("file://") ? spec.dropFirst("file://".count) : spec.dropFirst("file:".count))
            guard !path.isEmpty else { return nil }
        } else if !["/", ".", "~"].contains(where: { spec.hasPrefix($0) }) {
            return nil
        }
        return path.hasPrefix("/") ? .localProgram(path: path) : .command(name: path)
    }

    /// Trennt einen 40-stelligen Commit-Hash hinter `#` (npm) oder `@` (pip) ab. Das `@` einer SSH-Anmeldung
    /// (`git+ssh://git@host/…`) und Branches/Tags bleiben Teil des Ortes.
    private static func splitCommit(_ spec: String) -> (location: String, commit: String?) {
        for separator: Character in ["#", "@"] {
            guard let index = spec.lastIndex(of: separator), PackageSource.isCommitHash(spec[spec.index(after: index)...])
            else { continue }
            return (String(spec[..<index]), String(spec[spec.index(after: index)...]))
        }
        return (spec, nil)
    }

    // MARK: Hilfen

    /// Ergebnis von `firstOperand`.
    private struct OperandScan {
        /// Erstes Argument, das keine Option (und kein Optionswert) ist.
        var operand: String?
        /// Werte der erfassten Optionen in der Reihenfolge ihres Auftretens.
        var captured: [String]
        /// Die Argumente hinter dem Operanden.
        var rest: ArraySlice<String>
    }

    /// Erster Operand vor allen weiteren Argumenten: überspringt Optionen (`optionsWithValue` samt Wert, andere `-x` allein),
    /// erfasst die Werte von `capturing` (auch als `--option=wert`) und endet mit `nil`, sobald eine `aborting`-Option
    /// vorkommt. `--` beendet die Optionen.
    private static func firstOperand(
        in arguments: ArraySlice<String>,
        optionsWithValue: Set<String>,
        capturing: Set<String> = [],
        aborting: Set<String> = []
    ) -> OperandScan? {
        var captured: [String] = []
        var rest = arguments
        while let argument = rest.first {
            rest = rest.dropFirst()
            if argument == "--" { return OperandScan(operand: rest.first, captured: captured, rest: rest.dropFirst()) }
            if aborting.contains(argument) { return nil }
            if capturing.contains(argument) || optionsWithValue.contains(argument) {
                if capturing.contains(argument), let value = rest.first { captured.append(value) }
                rest = rest.dropFirst()
            } else if let option = capturing.first(where: { argument.hasPrefix($0 + "=") }) {
                captured.append(String(argument.dropFirst(option.count + 1)))
            } else if !argument.hasPrefix("-") {
                return OperandScan(operand: argument, captured: captured, rest: rest)
            }
        }
        return OperandScan(operand: nil, captured: captured, rest: [])
    }

    /// `nil` statt leerem Text – leere Namen und Versionen sind keine Angabe.
    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    private static func trimmed<Text: StringProtocol>(_ text: Text) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }
}
