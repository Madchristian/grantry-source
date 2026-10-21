import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct CleanupToolValidatorTests {
    @Test(arguments: ["tool", "parent", "alias"])
    func rejectsWritablePathComponent(component: String) throws {
        try ScratchDirectory.withCanonical(prefix: "tool-validation") { scratch in
            let directory = scratch.appending(path: "tools")
            let aliases = scratch.appending(path: "aliases")
            for path in [directory, aliases] {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            }
            let tool = directory.appending(path: "uv")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            let link = aliases.appending(path: "uv")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: tool.path)
            let validator = CleanupToolValidator()
            try validator.validate(link.path) // Unsigned scripts and normal Homebrew-style symlinks work.
            let unsafe = component == "tool" ? tool : component == "parent" ? directory : aliases
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: unsafe.path)
            #expect(throws: (any Error).self) { try validator.validate(link.path) }
        }
    }

    @Test func rejectsWriteACLButAllowsDenyOnlyACL() throws {
        try ScratchDirectory.withCanonical(prefix: "tool-acl") { scratch in
            let tool = scratch.appending(path: "uv")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            try AccessControlFixture.grant("everyone deny delete", to: tool.path)
            try CleanupToolValidator().validate(tool.path)
            try AccessControlFixture.grant("group:staff allow write", to: tool.path)
            #expect(throws: (any Error).self) { try CleanupToolValidator().validate(tool.path) }
        }
    }

    @Test func rejectsDamagedSignedExecutable() throws {
        try ScratchDirectory.withCanonical(prefix: "tool-signature") { scratch in
            let tool = scratch.appending(path: "uv")
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: tool.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            try CleanupToolValidator().validate(tool.path)
            let file = try FileHandle(forWritingTo: tool)
            defer { try? file.close() }
            // Change a sealed byte in the Mach-O text without executing the copied program.
            try file.seek(toOffset: 4096)
            try file.write(contentsOf: Data(repeating: 0xFF, count: 16))
            #expect(throws: (any Error).self) { try CleanupToolValidator().validate(tool.path) }
        }
    }

    @Test func acceptsSystemTool() throws {
        try CleanupToolValidator().validate("/usr/bin/true")
    }

    @Test func rejectsMissingOrRelativeTool() {
        #expect(throws: (any Error).self) { try CleanupToolValidator().validate("uv") }
        #expect(throws: (any Error).self) { try CleanupToolValidator().validate("/nonexistent/uv") }
    }
}
