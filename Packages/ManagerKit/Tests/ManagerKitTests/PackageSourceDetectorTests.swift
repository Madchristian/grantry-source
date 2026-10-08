import Testing
@testable import ManagerKit

@Suite struct PackageSourceDetectorTests {
    private func detect(_ command: String, _ arguments: [String] = []) -> PackageSource {
        PackageSourceDetector.detect(command: command, arguments: arguments)
    }

    @Test func npx() {
        #expect(detect("npx", ["-y", "@modelcontextprotocol/server-filesystem", "~/"])
            == .npm(package: "@modelcontextprotocol/server-filesystem", version: nil))
        #expect(detect("npx", ["pkg@1.2.3"]) == .npm(package: "pkg", version: "1.2.3"))
        #expect(detect("npx", ["--yes", "@scope/pkg@latest"]) == .npm(package: "@scope/pkg", version: "latest"))
        #expect(detect("/opt/homebrew/bin/npx", ["--package=tool@2.0.0", "tool-cli"]) == .npm(package: "tool", version: "2.0.0"))
        #expect(detect("npx", ["-p", "a@1.0.0", "a-bin"]) == .npm(package: "a", version: "1.0.0"))
    }

    @Test func otherNodeRunners() {
        #expect(detect("bunx", ["pkg@1.0.0"]) == .npm(package: "pkg", version: "1.0.0"))
        #expect(detect("pnpm", ["dlx", "pkg"]) == .npm(package: "pkg", version: nil))
        #expect(detect("yarn", ["dlx", "pkg@^1.0.0"]) == .npm(package: "pkg", version: "^1.0.0"))
        #expect(detect("npm", ["exec", "--yes", "--", "pkg@3.1.0"]) == .npm(package: "pkg", version: "3.1.0"))
    }

    @Test func python() {
        #expect(detect("uvx", ["pkg==1.0"]) == .pypi(package: "pkg", version: "1.0"))
        #expect(detect("uvx", ["--from", "pkg[cli]==2.1", "pkg-cmd"]) == .pypi(package: "pkg", version: "2.1"))
        #expect(detect("uvx", ["mcp-server-fetch"]) == .pypi(package: "mcp-server-fetch", version: nil))
        #expect(detect("uvx", ["pkg@0.4.0"]) == .pypi(package: "pkg", version: "0.4.0"))
        #expect(detect("uvx", ["pkg>=1"]) == .pypi(package: "pkg", version: nil))
        #expect(detect("uv", ["tool", "run", "pkg==1.0"]) == .pypi(package: "pkg", version: "1.0"))
        #expect(detect("pipx", ["run", "--spec", "pkg==3", "cmd"]) == .pypi(package: "pkg", version: "3"))
    }

    @Test func containers() {
        #expect(detect("docker", ["run", "-i", "--rm", "-e", "GITHUB_TOKEN", "ghcr.io/github/github-mcp-server:v1.2"])
            == .container(image: "ghcr.io/github/github-mcp-server", reference: "v1.2"))
        #expect(detect("docker", ["run", "mcp/fetch"]) == .container(image: "mcp/fetch", reference: nil))
        #expect(detect("podman", ["run", "--name=x", "localhost:5000/img@sha256:abc"])
            == .container(image: "localhost:5000/img", reference: "sha256:abc"))
    }

    @Test func localProgramsAndCommands() {
        #expect(detect("/usr/local/bin/my-server") == .localProgram(path: "/usr/local/bin/my-server"))
        #expect(detect("node", ["/Users/x/mcp/index.js", "--port", "1"]) == .localProgram(path: "/Users/x/mcp/index.js"))
        #expect(detect("python3", ["-u", "/opt/mcp/server.py"]) == .localProgram(path: "/opt/mcp/server.py"))
        #expect(detect("python3", ["-m", "server"]) == .command(name: "python3"))
        #expect(detect("node", ["build/index.js"]) == .command(name: "node"))
        #expect(detect("xcrun", ["mcpbridge"]) == .command(name: "xcrun"))
    }

    @Test func pinning() {
        #expect(PackageSource.npm(package: "a", version: "1.2.3").isUnpinned == false)
        #expect(PackageSource.npm(package: "a", version: nil).isUnpinned == true)
        #expect(PackageSource.npm(package: "a", version: "latest").isUnpinned == true)
        #expect(PackageSource.npm(package: "a", version: "^1.0.0").isUnpinned == true)
        #expect(PackageSource.npm(package: "a", version: "1.x").isUnpinned == true)
        #expect(PackageSource.pypi(package: "a", version: "1.0").isUnpinned == false)
        #expect(PackageSource.container(image: "a", reference: "latest").isUnpinned == true)
        #expect(PackageSource.container(image: "a", reference: "sha256:x").isUnpinned == false)
        #expect(PackageSource.localProgram(path: "/x").isUnpinned == false)
    }

    /// Unvollständige Argumente dürfen weder abstürzen (Index außerhalb) noch eine Quelle erfinden.
    @Test func incompleteArgumentsFallBackToCommand() {
        #expect(detect("npx") == .command(name: "npx"))
        #expect(detect("npx", ["-y"]) == .command(name: "npx"))
        #expect(detect("npx", ["--package"]) == .command(name: "npx"))
        #expect(detect("npx", ["-p"]) == .command(name: "npx"))
        #expect(detect("npx", ["-c", "echo"]) == .command(name: "npx"))
        #expect(detect("pnpm", ["dlx"]) == .command(name: "pnpm"))
        #expect(detect("npm", ["exec"]) == .command(name: "npm"))
        #expect(detect("npm", ["install"]) == .command(name: "npm"))
        #expect(detect("uvx") == .command(name: "uvx"))
        #expect(detect("uvx", ["--from"]) == .command(name: "uvx"))
        #expect(detect("uvx", ["--with"]) == .command(name: "uvx"))
        #expect(detect("uv", ["tool", "run"]) == .command(name: "uv"))
        #expect(detect("uv", ["run", "server.py"]) == .command(name: "uv"))
        #expect(detect("pipx", ["run", "--spec"]) == .command(name: "pipx"))
        #expect(detect("docker") == .command(name: "docker"))
        #expect(detect("docker", ["run"]) == .command(name: "docker"))
        #expect(detect("docker", ["run", "-i", "--rm"]) == .command(name: "docker"))
        #expect(detect("docker", ["run", "-e"]) == .command(name: "docker"))
        #expect(detect("docker", ["ps"]) == .command(name: "docker"))
        #expect(detect("python3", ["-u"]) == .command(name: "python3"))
        #expect(detect("node") == .command(name: "node"))
        #expect(detect("") == .command(name: ""))
    }

    /// Bei Interpretern zählt ein absolutes Skript; sonst bleibt der absolute Interpreter-Pfad selbst das lokale
    /// Programm (er muss in Signatur- und Ortsprüfung auftauchen). Ein bloßer Name bleibt ein `PATH`-Befehl.
    @Test func absoluteInterpreterPathsUseTheScript() {
        #expect(detect("/opt/homebrew/bin/node", ["/Users/x/index.js"]) == .localProgram(path: "/Users/x/index.js"))
        #expect(detect("/usr/bin/python3", ["-u", "/opt/mcp/server.py"]) == .localProgram(path: "/opt/mcp/server.py"))
        #expect(detect("/opt/homebrew/bin/node", ["build/index.js"]) == .localProgram(path: "/opt/homebrew/bin/node"))
        #expect(detect("/usr/bin/python3", ["-m", "server"]) == .localProgram(path: "/usr/bin/python3"))
        #expect(detect("/tmp/evil/python3", ["-m", "server"]) == .localProgram(path: "/tmp/evil/python3"))
        #expect(detect("/bin/bash") == .localProgram(path: "/bin/bash"))
        #expect(detect("node") == .command(name: "node"))
        #expect(detect("python3", ["-m", "server"]) == .command(name: "python3"))
        // Kein Interpreter: der Pfad selbst ist das Programm, Argumente ändern daran nichts.
        #expect(detect("/usr/local/bin/my-server", ["/etc/x"]) == .localProgram(path: "/usr/local/bin/my-server"))
    }

    /// `img:` und `img@` legen nichts fest – Docker nimmt dann `latest`.
    @Test func emptyContainerReferenceCountsAsUnpinned() {
        #expect(detect("docker", ["run", "img:"]) == .container(image: "img", reference: nil))
        #expect(detect("docker", ["run", "img@"]) == .container(image: "img", reference: nil))
        #expect(detect("docker", ["run", "localhost:5000/img:"]) == .container(image: "localhost:5000/img", reference: nil))
        #expect(detect("docker", ["run", "img:"]).isUnpinned == true)
    }

    /// Tag und Digest zusammen (`name:v1@sha256:…`): der Name bleibt ohne Tag, die Referenz ist der Digest.
    @Test func containerTagWithDigest() {
        #expect(detect("docker", ["run", "ghcr.io/x/y:v1@sha256:abc"])
            == .container(image: "ghcr.io/x/y", reference: "sha256:abc"))
        #expect(detect("podman", ["run", "localhost:5000/img:v1@sha256:abc"])
            == .container(image: "localhost:5000/img", reference: "sha256:abc"))
        #expect(detect("docker", ["run", "ghcr.io/x/y:v1@sha256:abc"]).isUnpinned == false)
    }

    @Test func npmOptionsWithSeparateValue() {
        #expect(detect("npx", ["--registry", "https://r.example", "pkg@1.0.0"]) == .npm(package: "pkg", version: "1.0.0"))
        #expect(detect("npx", ["--registry=https://r.example", "pkg@1.0.0"]) == .npm(package: "pkg", version: "1.0.0"))
        #expect(detect("npx", ["-y", "--cache", "/tmp/c", "--userconfig", "/tmp/rc", "--prefix", "/tmp/p", "pkg"])
            == .npm(package: "pkg", version: nil))
        #expect(detect("npx", ["--workspace", "a", "-w", "b", "pkg@2.0.0"]) == .npm(package: "pkg", version: "2.0.0"))
        #expect(detect("npx", ["--globalconfig", "/tmp/g", "--loglevel", "error", "pkg@1.0.0"])
            == .npm(package: "pkg", version: "1.0.0"))
        #expect(detect("npx", ["--node-options", "--inspect", "pkg"]) == .npm(package: "pkg", version: nil))
        #expect(detect("bunx", ["--registry", "https://r.example", "pkg@1.0.0"]) == .npm(package: "pkg", version: "1.0.0"))
        #expect(detect("pnpm", ["dlx", "--registry", "https://r.example", "pkg@1.0.0"]) == .npm(package: "pkg", version: "1.0.0"))
        #expect(detect("yarn", ["dlx", "--registry", "https://r.example", "pkg"]) == .npm(package: "pkg", version: nil))
        #expect(detect("npm", ["exec", "--registry", "https://r.example", "--", "pkg@3.1.0"]) == .npm(package: "pkg", version: "3.1.0"))
        // Option ohne Wert am Ende: keine Quelle erfinden.
        #expect(detect("npx", ["--registry"]) == .command(name: "npx"))
    }

    /// Leere Paket- oder Image-Namen ergeben keine Quelle, sondern den Befehl des Starters.
    @Test func emptyNamesFallBackToCommand() {
        #expect(detect("npx", [""]) == .command(name: "npx"))
        #expect(detect("npx", ["-y", ""]) == .command(name: "npx"))
        #expect(detect("npx", ["--package", "", "tool"]) == .command(name: "npx"))
        #expect(detect("pnpm", ["dlx", ""]) == .command(name: "pnpm"))
        #expect(detect("docker", ["run", ""]) == .command(name: "docker"))
        #expect(detect("docker", ["run", "-i", ":latest"]) == .command(name: "docker"))
        #expect(detect("docker", ["run", "@sha256:abc"]) == .command(name: "docker"))
        #expect(detect("uvx", [""]) == .command(name: "uvx"))
        #expect(detect("uvx", ["--from", "", "cmd"]) == .command(name: "uvx"))
        #expect(detect("uvx", ["==1.0"]) == .command(name: "uvx"))
        #expect(detect("uvx", ["[extra]"]) == .command(name: "uvx"))
        #expect(detect("pipx", ["run", ""]) == .command(name: "pipx"))
    }

    // MARK: Review: Versionen

    /// npm gilt nur bei vollständigem Semver (oder Commit-Hash) als festgelegt.
    @Test func npmVersionsNeedCompleteSemver() {
        for version in ["1", "1.2", "1.2.x", "v1", "~1.2.3", ">=1.2.3", "latest", String(commit.dropLast())] {
            #expect(PackageSource.npm(package: "a", version: version).isUnpinned == true, Comment(rawValue: version))
        }
        for version in ["1.2.3", "v1.2.3", "1.2.3+build", "1.2.3-beta.1", "1.2.3-beta.1+build.5", commit] {
            #expect(PackageSource.npm(package: "a", version: version).isUnpinned == false, Comment(rawValue: version))
        }
        #expect(detect("npx", ["pkg@1"]).isUnpinned == true)
        #expect(detect("npx", ["pkg@1.2"]).isUnpinned == true)
        #expect(detect("npx", ["pkg@v1.2.3"]).isUnpinned == false)
        #expect(detect("npx", ["pkg@1.2.3+build"]).isUnpinned == false)
    }

    @Test func pypiWildcardCountsAsUnpinned() {
        #expect(PackageSource.pypi(package: "a", version: "1.*").isUnpinned == true)
        #expect(PackageSource.pypi(package: "a", version: "1.0").isUnpinned == false)
        #expect(detect("uvx", ["pkg==1.*"]) == .pypi(package: "pkg", version: "1.*"))
        #expect(detect("uvx", ["pkg==1.*"]).isUnpinned == true)
        #expect(detect("uvx", ["pkg===1.0"]) == .pypi(package: "pkg", version: "1.0"))
        #expect(detect("uvx", ["pkg == 1.0 ; python_version < '3.13'"]) == .pypi(package: "pkg", version: "1.0"))
        // `uvx pkg@latest` legt nichts fest.
        #expect(detect("uvx", ["pkg@latest"]) == .pypi(package: "pkg", version: nil))
    }

    // MARK: Review: Docker/Podman

    @Test(arguments: containerOptionsWithValue)
    func containerOptionValueIsSkipped(option: String) {
        #expect(detect("docker", ["run", option, "x", "img:1"]) == .container(image: "img", reference: "1"))
    }

    @Test func containerGlobalOptionsAndSafetyNet() {
        let expected = PackageSource.container(image: "img", reference: "1")
        #expect(detect("docker", ["--context", "remote", "run", "img:1"]) == expected)
        #expect(detect("docker", ["-H", "unix:///var/run/docker.sock", "run", "img:1"]) == expected)
        #expect(detect("docker", ["--host", "tcp://h:2375", "run", "img:1"]) == expected)
        #expect(detect("docker", ["--config", "/c", "run", "img:1"]) == expected)
        #expect(detect("docker", ["--log-level", "debug", "run", "img:1"]) == expected)
        #expect(detect("docker", ["-D", "run", "img:1"]) == expected)
        #expect(detect("docker", ["--debug", "run", "img:1"]) == expected)
        #expect(detect("docker", ["container", "run", "img:1"]) == expected)
        #expect(detect("docker", ["--context", "x", "container", "run", "--rm", "img:1"]) == expected)
        #expect(detect("podman", ["--remote", "run", "img:1"]) == expected)
        // Unbekannte Option mit Pfadwert: der Pfad ist nie ein Image.
        #expect(detect("docker", ["run", "--neu", "/host/pfad", "img:1"]) == expected)
        #expect(detect("docker", ["run", "--neu", "./pfad", "img:1"]) == expected)
        #expect(detect("docker", ["run", "--neu", "../pfad"]) == .command(name: "docker"))
        #expect(detect("docker", ["--context", "x"]) == .command(name: "docker"))
    }

    // MARK: Review: Interpreter

    @Test func interpreterOptionsWithValue() {
        #expect(detect("node", ["-r", "dotenv/config", "/abs/i.js"]) == .localProgram(path: "/abs/i.js"))
        #expect(detect("node", ["--require", "/abs/hook.js", "/abs/i.js"]) == .localProgram(path: "/abs/i.js"))
        #expect(detect("node", ["--require=/abs/hook.js", "/abs/i.js"]) == .localProgram(path: "/abs/i.js"))
        #expect(detect("node", ["--import", "x", "--loader", "y", "--experimental-loader", "z", "/abs/i.js"])
            == .localProgram(path: "/abs/i.js"))
        #expect(detect("node", ["--env-file", ".env", "-C", "dev", "--conditions", "c", "--title", "t", "/abs/i.js"])
            == .localProgram(path: "/abs/i.js"))
        #expect(detect("python3", ["-X", "utf8", "/abs/s.py"]) == .localProgram(path: "/abs/s.py"))
        #expect(detect("python3", ["-W", "ignore", "/abs/s.py"]) == .localProgram(path: "/abs/s.py"))
        #expect(detect("ruby", ["-I", "lib", "-r", "json", "/abs/s.rb"]) == .localProgram(path: "/abs/s.rb"))
        #expect(detect("perl", ["-I", "lib", "/abs/s.pl"]) == .localProgram(path: "/abs/s.pl"))
        #expect(detect("deno", ["run", "--config", "/abs/deno.json", "--import-map", "m.json", "/abs/main.ts"])
            == .localProgram(path: "/abs/main.ts"))
        #expect(detect("deno", ["run", "--env-file", ".env", "--location", "https://x", "/abs/main.ts"])
            == .localProgram(path: "/abs/main.ts"))
        // Wert der Option ist kein Skript.
        #expect(detect("node", ["-r", "/abs/hook.js", "build/i.js"]) == .command(name: "node"))
    }

    @Test func versionedPythonNames() {
        #expect(detect("python3.12", ["/abs/s.py"]) == .localProgram(path: "/abs/s.py"))
        #expect(detect("python3.11", ["-u", "/abs/s.py"]) == .localProgram(path: "/abs/s.py"))
        #expect(detect("/opt/homebrew/bin/python3.13", ["/abs/s.py"]) == .localProgram(path: "/abs/s.py"))
        #expect(detect("python3.12", ["-m", "server"]) == .command(name: "python3.12"))
        #expect(detect("/usr/bin/python3.12", ["-m", "server"]) == .localProgram(path: "/usr/bin/python3.12"))
        #expect(detect("python2", ["/abs/s.py"]) == .localProgram(path: "/abs/s.py"))
        #expect(detect("python3x", ["/abs/s.py"]) == .command(name: "python3x"))
    }

    // MARK: Review: env

    @Test func envWrapper() {
        #expect(detect("/usr/bin/env", ["node", "/abs/x.js"]) == .localProgram(path: "/abs/x.js"))
        #expect(detect("env", ["FOO=1", "npx", "-y", "pkg"]) == .npm(package: "pkg", version: nil))
        #expect(detect("env", ["-i", "-u", "HOME", "FOO=1", "node", "/abs/x.js"]) == .localProgram(path: "/abs/x.js"))
        #expect(detect("env", ["--unset=HOME", "uvx", "pkg==1.0"]) == .pypi(package: "pkg", version: "1.0"))
        #expect(detect("env", ["--unset", "HOME", "docker", "run", "img:1"]) == .container(image: "img", reference: "1"))
        #expect(detect("/usr/bin/env", ["/opt/mcp/server"]) == .localProgram(path: "/opt/mcp/server"))
        #expect(detect("env", ["./server"]) == .command(name: "./server"))
        // `-S` nimmt den Rest als einen String; ohne Befehl bleibt nur `env`.
        #expect(detect("env", ["-S", "node /abs/x.js"]) == .command(name: "env"))
        #expect(detect("env", ["--split-string=node x"]) == .command(name: "env"))
        #expect(detect("/usr/bin/env", ["-S", "node /abs/x.js"]) == .localProgram(path: "/usr/bin/env"))
        #expect(detect("env") == .command(name: "env"))
        #expect(detect("env", ["FOO=1"]) == .command(name: "env"))
        #expect(detect("env", ["env", "env"]) == .command(name: "env"))
    }

    // MARK: Review: Pfad-, Git- und URL-Angaben

    /// Nur absolute Pfade sind `.localProgram`; relative hängen vom Arbeitsverzeichnis ab und bleiben `.command`.
    @Test func npmPathSpecs() {
        #expect(detect("npx", ["/abs/pkg"]) == .localProgram(path: "/abs/pkg"))
        #expect(detect("npx", ["file:///abs/x"]) == .localProgram(path: "/abs/x"))
        #expect(detect("npx", ["file:/abs/pkg"]) == .localProgram(path: "/abs/pkg"))
        #expect(detect("npx", ["--package", "/abs/tool", "tool-cli"]) == .localProgram(path: "/abs/tool"))
        #expect(detect("npx", ["./local"]) == .command(name: "./local"))
        #expect(detect("npx", ["-y", "./local"]) == .command(name: "./local"))
        #expect(detect("npx", ["-y", "../lokal"]) == .command(name: "../lokal"))
        #expect(detect("npx", ["~/x"]) == .command(name: "~/x"))
        #expect(detect("npx", ["."]) == .command(name: "."))
        #expect(detect("npx", ["file:../x"]) == .command(name: "../x"))
        #expect(detect("npx", ["--package", "./tool", "tool-cli"]) == .command(name: "./tool"))
        #expect(detect("npx", ["./local"]).isUnpinned == false)
    }

    @Test func npmGitAndUrlSpecs() {
        let repo = "git+https://github.com/x/y.git"
        #expect(detect("npx", [repo]) == .npm(package: repo, version: nil))
        #expect(detect("npx", [repo]).isUnpinned == true)
        #expect(detect("npx", [repo + "#" + commit]) == .npm(package: repo, version: commit))
        #expect(detect("npx", [repo + "#" + commit]).isUnpinned == false)
        #expect(detect("npx", [repo + "#main"]) == .npm(package: repo + "#main", version: nil))
        #expect(detect("npx", [repo + "#semver:^1"]).isUnpinned == true)
        // Das `@` der SSH-Anmeldung ist kein Versionstrenner.
        let ssh = "git+ssh://git@github.com/x/y.git"
        #expect(detect("npx", [ssh]) == .npm(package: ssh, version: nil))
        #expect(detect("npx", [ssh + "#" + commit]) == .npm(package: ssh, version: commit))
        #expect(detect("npx", ["github:user/repo"]) == .npm(package: "github:user/repo", version: nil))
        #expect(detect("npx", ["github:user/repo#" + commit]) == .npm(package: "github:user/repo", version: commit))
        #expect(detect("npx", ["https://example.com/pkg.tgz"]) == .npm(package: "https://example.com/pkg.tgz", version: nil))
        #expect(detect("npx", ["https://example.com/pkg.tgz"]).isUnpinned == true)
    }

    @Test func pypiPathGitAndUrlSpecs() {
        let repo = "git+https://github.com/x/y"
        #expect(detect("uvx", ["./local"]) == .command(name: "./local"))
        #expect(detect("uvx", ["--from", "~/pkg", "cmd"]) == .command(name: "~/pkg"))
        #expect(detect("uvx", ["--from", "/abs/pkg", "cmd"]) == .localProgram(path: "/abs/pkg"))
        // PEP 508 mit `file:`-URL läuft über dieselbe Pfadprüfung; Web-URLs bleiben PyPI-Pakete.
        #expect(detect("uvx", ["--from", "pkg @ file:///abs/pkg", "cmd"]) == .localProgram(path: "/abs/pkg"))
        #expect(detect("uvx", ["--from", "pkg @ file:../pkg", "cmd"]) == .command(name: "../pkg"))
        #expect(detect("uvx", ["--from", repo, "cmd"]) == .pypi(package: repo, version: nil))
        #expect(detect("uvx", ["--from", repo + "@" + commit, "cmd"]) == .pypi(package: repo, version: commit))
        #expect(detect("uvx", ["--from", repo + "@" + commit, "cmd"]).isUnpinned == false)
        #expect(detect("uvx", ["--from", repo + "@v1.0", "cmd"]) == .pypi(package: repo + "@v1.0", version: nil))
        #expect(detect("uvx", ["--from", repo + ".git#" + commit, "cmd"]) == .pypi(package: repo + ".git", version: commit))
        let ssh = "git+ssh://git@github.com/x/y.git"
        #expect(detect("uvx", ["--from", ssh, "cmd"]) == .pypi(package: ssh, version: nil))
        // PEP 508: `name @ url`.
        #expect(detect("uvx", ["--from", "pkg @ " + repo + "@" + commit, "cmd"]) == .pypi(package: "pkg", version: commit))
        #expect(detect("uvx", ["--from", "pkg[extra] @ " + repo, "cmd"]) == .pypi(package: "pkg", version: nil))
        #expect(detect("uvx", ["--from", "pkg @ https://example.com/pkg.whl", "cmd"]) == .pypi(package: "pkg", version: nil))
        #expect(detect("pipx", ["run", "--spec", repo + "@" + commit, "cmd"]) == .pypi(package: repo, version: commit))
    }

    // MARK: Review: uvx/pipx-Optionen

    @Test(arguments: pypiOptionsWithValue)
    func pypiOptionValueIsSkipped(option: String) {
        #expect(detect("uvx", [option, "x", "pkg==1.0"]) == .pypi(package: "pkg", version: "1.0"))
        #expect(detect("pipx", ["run", option, "x", "pkg==1.0"]) == .pypi(package: "pkg", version: "1.0"))
    }

    @Test func firstSpecOptionWins() {
        #expect(detect("uvx", ["--from", "a==1", "--from", "b==2", "cmd"]) == .pypi(package: "a", version: "1"))
        #expect(detect("uvx", ["--from=a==1", "cmd"]) == .pypi(package: "a", version: "1"))
        #expect(detect("npx", ["-p", "a@1.0.0", "--package", "b@2.0.0", "cmd"]) == .npm(package: "a", version: "1.0.0"))
        #expect(detect("uvx", ["--", "pkg==1.0"]) == .pypi(package: "pkg", version: "1.0"))
    }

    // MARK: Review: deno

    @Test func denoNpmSpecifiers() {
        #expect(detect("deno", ["run", "npm:@scope/pkg@1.2.3"]) == .npm(package: "@scope/pkg", version: "1.2.3"))
        #expect(detect("deno", ["run", "--allow-all", "npm:pkg"]) == .npm(package: "pkg", version: nil))
        #expect(detect("deno", ["run", "-A", "npm:pkg@^1"]).isUnpinned == true)
        // `jsr:` und entfernte Module werden nicht aufgelöst.
        #expect(detect("deno", ["run", "jsr:@std/http"]) == .command(name: "deno"))
        #expect(detect("deno", ["run", "https://example.com/m.ts"]) == .command(name: "deno"))
        #expect(detect("deno", ["run", "/abs/main.ts"]) == .localProgram(path: "/abs/main.ts"))
        #expect(detect("node", ["npm:pkg"]) == .command(name: "node"))
    }

    // MARK: Review: Programmpfade und Grenzen

    @Test func relativeProgramPathsKeepTheFullPath() {
        #expect(detect("./bin/server") == .command(name: "./bin/server"))
        #expect(detect("~/bin/server", ["--x"]) == .command(name: "~/bin/server"))
        #expect(detect("../tools/server") == .command(name: "../tools/server"))
        // Runner und Interpreter werden nur als Name oder absoluter Pfad erkannt.
        #expect(detect("./node_modules/.bin/npx", ["pkg@1.0.0"]) == .command(name: "./node_modules/.bin/npx"))
        #expect(detect("bin/node", ["/abs/i.js"]) == .command(name: "bin/node"))
    }

    @Test func absoluteRunnerPathsStayLocalPrograms() {
        #expect(detect("/opt/homebrew/bin/npx", ["pkg@1.0.0"]) == .npm(package: "pkg", version: "1.0.0"))
        #expect(detect("/opt/homebrew/bin/npx") == .localProgram(path: "/opt/homebrew/bin/npx"))
        #expect(detect("/usr/local/bin/docker", ["ps"]) == .localProgram(path: "/usr/local/bin/docker"))
        #expect(detect("/usr/local/bin/uvx") == .localProgram(path: "/usr/local/bin/uvx"))
    }

    /// Jeder Interpreter hat eigene Optionen: `-I` ist bei Python ein Schalter, bei Ruby/Perl ein Option mit Wert.
    @Test func interpreterOptionsPerInterpreter() {
        // Python: -X/-W mit Wert, -I/-E/-s/-u/-B Schalter, -m/-c beenden.
        #expect(detect("python3", ["-I", "/abs/s.py"]) == .localProgram(path: "/abs/s.py"))
        #expect(detect("python3", ["-E", "-s", "-u", "-B", "/abs/s.py"]) == .localProgram(path: "/abs/s.py"))
        #expect(detect("python3", ["-I", "-X", "utf8", "-W", "error", "/abs/s.py"]) == .localProgram(path: "/abs/s.py"))
        #expect(detect("python3", ["-I", "-c", "print(1)"]) == .command(name: "python3"))
        // Shell: -e/-x/-u Schalter, -c beendet; -o nimmt einen Wert.
        #expect(detect("bash", ["-e", "/abs/x.sh"]) == .localProgram(path: "/abs/x.sh"))
        #expect(detect("sh", ["-x", "/abs/x.sh"]) == .localProgram(path: "/abs/x.sh"))
        #expect(detect("zsh", ["-e", "-u", "/abs/x.zsh"]) == .localProgram(path: "/abs/x.zsh"))
        #expect(detect("bash", ["-eu", "/abs/x.sh"]) == .localProgram(path: "/abs/x.sh"))
        #expect(detect("bash", ["-o", "pipefail", "/abs/x.sh"]) == .localProgram(path: "/abs/x.sh"))
        #expect(detect("bash", ["-e", "-c", "npx -y pkg"]) == .command(name: "bash"))
        #expect(detect("/bin/bash", ["-e", "-c", "echo"]) == .localProgram(path: "/bin/bash"))
        #expect(detect("bash", ["-e"]) == .command(name: "bash"))
        // Perl/Ruby: -W Schalter, -I/-r mit Wert, -e beendet.
        #expect(detect("perl", ["-W", "-I", "lib", "/abs/s.pl"]) == .localProgram(path: "/abs/s.pl"))
        #expect(detect("ruby", ["-W", "-I", "lib", "-r", "json", "/abs/s.rb"]) == .localProgram(path: "/abs/s.rb"))
        #expect(detect("ruby", ["-e", "puts 1"]) == .command(name: "ruby"))
        #expect(detect("perl", ["-e", "print 1"]) == .command(name: "perl"))
        // Deno: -c ist die Konfigurationsdatei (mit Wert), kein Abbruch.
        #expect(detect("deno", ["run", "-c", "deno.json", "/abs/main.ts"]) == .localProgram(path: "/abs/main.ts"))
        #expect(detect("deno", ["run", "-A", "-c", "deno.json", "npm:pkg@1.0.0"]) == .npm(package: "pkg", version: "1.0.0"))
        // Node: `-r` und `-C` mit Wert, `-p` beendet.
        #expect(detect("node", ["-p", "1+1"]) == .command(name: "node"))
    }

    @Test func bunExecutesPackagesLikeBunx() {
        #expect(detect("bun", ["x", "pkg@1.0.0"]) == .npm(package: "pkg", version: "1.0.0"))
        #expect(detect("bun", ["x", "--bun", "@scope/pkg"]) == .npm(package: "@scope/pkg", version: nil))
        #expect(detect("bun", ["x"]) == .command(name: "bun"))
        #expect(detect("/opt/homebrew/bin/bun", ["x", "pkg"]) == .npm(package: "pkg", version: nil))
        #expect(detect("bun", ["run", "/abs/i.ts"]) == .localProgram(path: "/abs/i.ts"))
        #expect(detect("bun", ["/abs/i.ts"]) == .localProgram(path: "/abs/i.ts"))
    }

    @Test func documentedLimits() {
        // Unbekannte docker-Optionen mit Wert: der Wert gilt als Image, außer er beginnt mit `/` oder `.`.
        #expect(detect("docker", ["run", "--neu", "wert", "img:1"]) == .container(image: "wert", reference: nil))
        // Globale Optionen vor dem Unterkommando werden nicht aufgelöst.
        #expect(detect("pnpm", ["--silent", "dlx", "pkg"]) == .command(name: "pnpm"))
        #expect(detect("uv", ["--quiet", "tool", "run", "pkg"]) == .command(name: "uv"))
        // Shell-Wrapper und Runner, die ein anderes Programm starten, zählen nur als Befehl bzw. erstes Paket.
        #expect(detect("bash", ["-c", "npx -y pkg"]) == .command(name: "bash"))
        #expect(detect("npx", ["-c", "echo hi"]) == .command(name: "npx"))
        #expect(detect("npx", ["tsx", "server.ts"]) == .npm(package: "tsx", version: nil))
    }
}

private let commit = "0123456789abcdef0123456789abcdef01234567"

/// Optionen von `docker run`/`podman run` mit Wert als eigenem Argument (Auszug, bewusst breit gestreut).
private let containerOptionsWithValue = [
    "-e", "--env", "--env-file", "-v", "--volume", "--mount", "--name", "-p", "--publish", "--network", "--net",
    "-w", "--workdir", "-u", "--user", "--entrypoint", "-l", "--label", "--platform", "--add-host", "--cap-add",
    "--cap-drop", "--device", "-m", "--memory", "--cpus", "--pull", "--restart", "-h", "--hostname", "--ipc", "--pid",
    "--security-opt", "--tmpfs", "--ulimit", "--log-driver", "--log-opt", "--runtime", "--shm-size", "--dns",
    "--expose", "--gpus", "--group-add", "--label-file", "--mac-address", "--stop-signal", "--stop-timeout",
    "-a", "--attach", "--cidfile", "-c", "--cpu-shares", "--cpuset-cpus", "--memory-swap", "--cgroup-parent",
    "--cgroupns", "--userns", "--uts", "--volumes-from", "--link", "--sysctl", "--ip", "--ip6", "--network-alias",
    "--dns-search", "--dns-option", "--domainname", "--health-cmd", "--health-interval", "--health-retries",
    "--health-timeout", "--health-start-period", "--pids-limit", "--oom-score-adj", "--detach-keys", "--storage-opt",
    "--annotation", "--isolation", "--blkio-weight", "--pod", "--arch", "--os", "--variant", "--secret",
]

/// Optionen von `uvx`/`uv tool run`/`pipx run` mit Wert als eigenem Argument.
private let pypiOptionsWithValue = [
    "--with", "-w", "--python", "-p", "--index-url", "--extra-index-url", "--index", "--pip-args", "--suffix",
    "--with-requirements", "--with-editable", "-c", "--constraint", "--overrides", "-f", "--find-links",
    "--default-index", "--index-strategy", "--keyring-provider", "--python-preference", "--cache-dir", "--config-file",
    "--exclude-newer", "--resolution", "--prerelease", "--refresh-package", "-P", "--upgrade-package",
    "--reinstall-package", "--env-file", "--directory", "--project",
]
