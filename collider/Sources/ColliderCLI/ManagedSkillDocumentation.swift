import ArgumentParser
import ColliderCore
import Foundation
import SystemPackage

enum ManagedSkill: String, CaseIterable, ExpressibleByArgument {
    case collider
    case swiftCxxInterop = "swift-cxx-interop"
}

enum GeneratedSkill: String, CaseIterable, ExpressibleByArgument {
    case collider
}

enum SynchronizedSkill: String, CaseIterable, ExpressibleByArgument {
    case swiftCxxInterop = "swift-cxx-interop"
}

enum ManagedSkillDocumentation {
    static func verifyAll(at repositoryRoot: FilePath) throws -> [String] {
        try ManagedSkill.allCases.map { skill in
            try verify(skill, at: repositoryRoot)
        }
    }

    static func verify(_ skill: ManagedSkill, at repositoryRoot: FilePath) throws -> String {
        switch skill {
        case .collider:
            try verify(
                ColliderSkillDocumentation.documents(),
                under: repositoryRoot.appending(ColliderSkillDocumentation.root))
            return "verified .agents/skills/collider against the current Collider grammar"
        case .swiftCxxInterop:
            return try SwiftCxxInteropSkillDocumentation.verifyLatest(at: repositoryRoot)
        }
    }

    static func verify(
        _ expected: [String: Data],
        under root: FilePath
    ) throws {
        for (relativePath, expectedContents) in expected {
            let path = root.appending(relativePath)
            let checkedIn: Data
            do {
                checkedIn = try Data(contentsOf: URL(fileURLWithPath: path.string))
            } catch {
                throw SkillDocumentationFailure.unreadable(path, error)
            }
            guard checkedIn == expectedContents else {
                throw SkillDocumentationFailure.outOfDate(path)
            }
        }
    }
}

enum SwiftCxxInteropSkillDocumentation {
    struct UpstreamSnapshot {
        let revision: String
        let documentation: Data
        let safeInterop: Data
        let license: Data
    }

    static let root = ".agents/skills/swift-cxx-interop"

    private static let upstreamRepository =
        "https://github.com/swiftlang/swift-org-website.git"
    private static let documentationPath = "documentation/cxx-interop/index.md"
    private static let safeInteropPath = "documentation/cxx-interop/safe-interop/index.md"
    private static let licensePath = "LICENSE.txt"

    static func sync(to repositoryRoot: FilePath) throws -> String {
        let upstream = try fetchLatest()
        let skillRoot = repositoryRoot.appending(root)
        let checkedInDocumentation = try? read(
            skillRoot.appending("references/mixing-swift-and-cxx.md"))
        let checkedInSafeInterop = try? read(
            skillRoot.appending("references/safe-interop.md"))
        let checkedInLicense = try? read(
            skillRoot.appending("references/swift-org-license.txt"))
        let contentMatches =
            checkedInDocumentation == upstream.documentation
            && checkedInSafeInterop == upstream.safeInterop
            && checkedInLicense == upstream.license
        let recordedRevision = try? checkedInRevision(at: skillRoot)
        let provenanceRevision =
            contentMatches
            ? recordedRevision ?? upstream.revision
            : upstream.revision
        let documents = try synchronizedDocuments(
            documentation: upstream.documentation,
            safeInterop: upstream.safeInterop,
            license: upstream.license,
            revision: provenanceRevision)
        if documentsMatch(documents, under: skillRoot) {
            return
                "swift-cxx-interop already matches the latest Swift.org content at revision \(upstream.revision)"
        }
        try write(documents, to: skillRoot)
        if contentMatches {
            return
                "repaired generated swift-cxx-interop metadata; upstream content remains current at revision \(upstream.revision)"
        }
        return
            "synchronized .agents/skills/swift-cxx-interop from Swift.org revision \(upstream.revision)"
    }

    static func fetchLatest() throws -> UpstreamSnapshot {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nucleus-swift-cxx-interop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let checkout = temporaryRoot.appendingPathComponent("swift-org-website")
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true)
        _ = try runGit([
            "clone", "--quiet", "--depth", "1", "--filter=blob:none", "--no-checkout",
            upstreamRepository, checkout.path,
        ])
        let revision = try utf8(
            runGit(["-C", checkout.path, "rev-parse", "HEAD"]),
            label: "upstream revision"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard validGitRevision(revision) else {
            throw SkillDocumentationFailure.invalid(
                "Swift.org returned invalid Git revision '\(revision)'")
        }
        let documentationSource = try runGit([
            "-C", checkout.path, "show", "\(revision):\(documentationPath)",
        ])
        let safeInteropSource = try runGit([
            "-C", checkout.path, "show", "\(revision):\(safeInteropPath)",
        ])
        let documentation = try renderTableOfContents(in: documentationSource)
        let safeInterop = try renderTableOfContents(in: safeInteropSource)
        let license = try runGit([
            "-C", checkout.path, "show", "\(revision):\(licensePath)",
        ])
        _ = try synchronizedDocuments(
            documentation: documentation,
            safeInterop: safeInterop,
            license: license,
            revision: revision)
        return UpstreamSnapshot(
            revision: revision,
            documentation: documentation,
            safeInterop: safeInterop,
            license: license)
    }

    static func verifyLatest(at repositoryRoot: FilePath) throws -> String {
        try verifyCheckedIn(at: repositoryRoot)
        let upstream = try fetchLatest()
        try verify(upstream, at: repositoryRoot)
        return
            "verified .agents/skills/swift-cxx-interop against the latest Swift.org content at revision \(upstream.revision)"
    }

    static func verify(_ upstream: UpstreamSnapshot, at repositoryRoot: FilePath) throws {
        let skillRoot = repositoryRoot.appending(root)
        let checkedInRevision = try checkedInRevision(at: skillRoot)
        let documentation = try read(
            skillRoot.appending("references/mixing-swift-and-cxx.md"))
        let safeInterop = try read(
            skillRoot.appending("references/safe-interop.md"))
        let license = try read(
            skillRoot.appending("references/swift-org-license.txt"))
        guard documentation == upstream.documentation,
            safeInterop == upstream.safeInterop,
            license == upstream.license
        else {
            throw SkillDocumentationFailure.upstreamOutOfDate(
                checkedInRevision: checkedInRevision,
                upstreamRevision: upstream.revision)
        }
    }

    static func verifyCheckedIn(at repositoryRoot: FilePath) throws {
        let skillRoot = repositoryRoot.appending(root)
        try validateSkillStructure(at: skillRoot)

        let documentation = try read(
            skillRoot.appending("references/mixing-swift-and-cxx.md"))
        let safeInterop = try read(
            skillRoot.appending("references/safe-interop.md"))
        let license = try read(
            skillRoot.appending("references/swift-org-license.txt"))
        let provenance = try utf8(
            read(skillRoot.appending("references/upstream.md")),
            label: "upstream provenance")
        let revision = try provenanceValue("Revision", in: provenance)
        guard validGitRevision(revision) else {
            throw SkillDocumentationFailure.invalid(
                "Swift/C++ skill provenance has invalid Git revision '\(revision)'")
        }
        let expected = try synchronizedDocuments(
            documentation: documentation,
            safeInterop: safeInterop,
            license: license,
            revision: revision)
        try ManagedSkillDocumentation.verify(expected, under: skillRoot)
    }

    static func synchronizedDocuments(
        documentation: Data,
        safeInterop: Data,
        license: Data,
        revision: String
    ) throws -> [String: Data] {
        let source = try utf8(documentation, label: "Swift/C++ interoperability guide")
        guard source.hasPrefix("---\n"),
            source.contains("title: Mixing Swift and C++"),
            !source.contains("{:.no_toc}"),
            !source.contains("{:toc}"),
            source.contains("## Introduction"),
            source.contains("## Appendix")
        else {
            throw SkillDocumentationFailure.invalid(
                "Swift.org Swift/C++ interoperability guide has an unexpected structure")
        }
        let safeInteropSource = try utf8(
            safeInterop,
            label: "Swift/C++ safe interoperability guide")
        guard safeInteropSource.hasPrefix("---\n"),
            safeInteropSource.contains("title: Safely Mixing Swift and C/C++"),
            !safeInteropSource.contains("{:.no_toc}"),
            !safeInteropSource.contains("{:toc}"),
            safeInteropSource.contains("## Introduction"),
            safeInteropSource.contains("## Lifetime Annotations in Detail")
        else {
            throw SkillDocumentationFailure.invalid(
                "Swift.org Swift/C++ safe interoperability guide has an unexpected structure")
        }
        let licenseText = try utf8(license, label: "Swift.org license")
        guard licenseText.contains("Apache License"),
            licenseText.contains("Version 2.0")
        else {
            throw SkillDocumentationFailure.invalid(
                "Swift.org license is not the expected Apache License 2.0 text")
        }
        guard validGitRevision(revision) else {
            throw SkillDocumentationFailure.invalid(
                "invalid Swift.org Git revision '\(revision)'")
        }

        return [
            "references/mixing-swift-and-cxx.md": documentation,
            "references/safe-interop.md": safeInterop,
            "references/swift-org-license.txt": license,
            "references/topic-index.md": Data(
                topicIndex(for: source, safeInterop: safeInteropSource).utf8),
            "references/upstream.md": Data(
                provenance(
                    revision: revision,
                    documentation: documentation,
                    safeInterop: safeInterop,
                    license: license
                ).utf8),
        ]
    }

    static func topicIndex(for source: String, safeInterop: String) -> String {
        var sections: [String] = [
            "# Topic index",
            "",
            "Both vendored pages preserve the canonical Swift.org content with the site-only Jekyll TOC placeholders expanded into linked Markdown tables of contents. The generated heading tables below provide exact line ranges for agent navigation.",
            "",
        ]
        appendHeadingIndex(
            for: source,
            file: "mixing-swift-and-cxx.md",
            title: "Mixing Swift and C++",
            to: &sections)
        appendHeadingIndex(
            for: safeInterop,
            file: "safe-interop.md",
            title: "Safely Mixing Swift and C/C++",
            to: &sections)
        sections.append(contentsOf: [
            "## Live companion pages",
            "",
            "These companion pages are not duplicated here:",
            "",
            "- [Supported features and constraints](https://www.swift.org/documentation/cxx-interop/status/)",
            "- [Mixed-language project and build setup](https://www.swift.org/documentation/cxx-interop/project-build-setup/)",
            "",
            "Consult them for toolchain/platform support, current limitations, and build-system behavior that may have changed after the vendored revision.",
            "",
        ])
        return sections.joined(separator: "\n")
    }

    private static func appendHeadingIndex(
        for source: String,
        file: String,
        title: String,
        to sections: inout [String]
    ) {
        var lines = source.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        let headings = lines.enumerated().compactMap { index, line -> (Int, Int, String)? in
            let level = line.prefix(while: { $0 == "#" }).count
            guard level >= 2, level <= 4, line.dropFirst(level).hasPrefix(" ") else {
                return nil
            }
            return (index + 1, level, String(line.dropFirst(level + 1)))
        }
        sections.append(contentsOf: [
            "## \(title)",
            "",
            "Read `\(file)` with `sed -n '<start>,<end>p'` using these ranges.",
            "",
            "| Lines | Section |",
            "| ---: | --- |",
        ])
        for (index, heading) in headings.enumerated() {
            let start = heading.0
            let end = index + 1 < headings.count ? headings[index + 1].0 - 1 : lines.count
            let indentation = String(repeating: "↳ ", count: heading.1 - 2)
            sections.append("| \(start)–\(end) | \(indentation)\(heading.2) |")
        }
        sections.append(contentsOf: [
            "",
            "Use `rg -n '^##+ ' references/\(file)` for direct heading lookup.",
            "",
        ])
    }

    private static func provenance(
        revision: String,
        documentation: Data,
        safeInterop: Data,
        license: Data
    ) -> String {
        """
        # Upstream provenance

        The vendored Markdown files are deterministic agent-oriented renderings of:

        - Project: Swift.org website
        - Repository: https://github.com/swiftlang/swift-org-website
        - Main guide path: `\(documentationPath)`
        - Safe interoperability path: `\(safeInteropPath)`
        - Revision: `\(revision)`
        - Main guide SHA-256: `\(ArtifactDigest.sha256(documentation).hexadecimal)`
        - Safe interoperability SHA-256: `\(ArtifactDigest.sha256(safeInterop).hexadecimal)`
        - License SHA-256: `\(ArtifactDigest.sha256(license).hexadecimal)`
        - Main guide page: https://www.swift.org/documentation/cxx-interop/
        - Safe interoperability page: https://www.swift.org/documentation/cxx-interop/safe-interop/

        Collider preserves the upstream prose and examples and replaces only each site-only TOC placeholder block with the linked Markdown table of contents that it represents on Swift.org. The recorded guide hashes cover those rendered files. The upstream repository distributes the documentation under the Apache License, Version 2.0; the complete upstream license is preserved in `swift-org-license.txt`.
        """ + "\n"
    }

    static func renderTableOfContents(in documentation: Data) throws -> Data {
        let source = try utf8(documentation, label: "Swift.org documentation")
        let placeholder = "## Table of Contents\n{:.no_toc}\n\n* TOC\n{:toc}"
        guard source.components(separatedBy: placeholder).count == 2 else {
            throw SkillDocumentationFailure.invalid(
                "Swift.org documentation has an unexpected table-of-contents placeholder")
        }
        let headings = source.components(separatedBy: "\n").compactMap {
            line -> (level: Int, title: String)? in
            let level = line.prefix(while: { $0 == "#" }).count
            guard level >= 2, level <= 4, line.dropFirst(level).hasPrefix(" ") else {
                return nil
            }
            let title = String(line.dropFirst(level + 1))
            guard title != "Table of Contents" else { return nil }
            return (level, title)
        }
        guard !headings.isEmpty else {
            throw SkillDocumentationFailure.invalid(
                "Swift.org documentation has no headings for its table of contents")
        }
        let entries = headings.map { heading in
            let indentation = String(repeating: "  ", count: heading.level - 2)
            return "\(indentation)- [\(heading.title)](#\(headingAnchor(heading.title)))"
        }
        let rendered = source.replacingOccurrences(
            of: placeholder,
            with: (["## Table of Contents", ""] + entries).joined(separator: "\n"))
        return Data(rendered.utf8)
    }

    private static func headingAnchor(_ title: String) -> String {
        var anchor = ""
        var pendingHyphen = false
        for character in title.lowercased() {
            if character.isLetter || character.isNumber || character == "_" {
                if pendingHyphen, !anchor.isEmpty { anchor.append("-") }
                anchor.append(character)
                pendingHyphen = false
            } else if character.isWhitespace || character == "-" {
                pendingHyphen = true
            }
        }
        return anchor
    }

    private static func validateSkillStructure(at skillRoot: FilePath) throws {
        let skill = try utf8(read(skillRoot.appending("SKILL.md")), label: "SKILL.md")
        guard skill.hasPrefix("---\nname: swift-cxx-interop\n"),
            skill.contains("\ndescription: "),
            skill.contains("\n---\n")
        else {
            throw SkillDocumentationFailure.invalid(
                "Swift/C++ skill has invalid SKILL.md frontmatter")
        }
        let metadata = try utf8(
            read(skillRoot.appending("agents/openai.yaml")),
            label: "agents/openai.yaml")
        guard metadata.contains("display_name: \"Swift/C++ Interop\""),
            metadata.contains("$swift-cxx-interop")
        else {
            throw SkillDocumentationFailure.invalid(
                "Swift/C++ skill has invalid agent metadata")
        }
    }

    private static func checkedInRevision(at skillRoot: FilePath) throws -> String {
        let provenance = try utf8(
            read(skillRoot.appending("references/upstream.md")),
            label: "upstream provenance")
        let revision = try provenanceValue("Revision", in: provenance)
        guard validGitRevision(revision) else {
            throw SkillDocumentationFailure.invalid(
                "Swift/C++ skill provenance has invalid Git revision '\(revision)'")
        }
        return revision
    }

    private static func provenanceValue(_ name: String, in provenance: String) throws -> String {
        let prefix = "- \(name): `"
        guard
            let line = provenance.split(separator: "\n").first(where: {
                $0.hasPrefix(prefix)
            }), line.hasSuffix("`")
        else {
            throw SkillDocumentationFailure.invalid(
                "Swift/C++ skill provenance is missing \(name)")
        }
        return String(line.dropFirst(prefix.count).dropLast())
    }

    private static func validGitRevision(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.utf8.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            }
    }

    private static func write(_ documents: [String: Data], to root: FilePath) throws {
        for (relativePath, contents) in documents {
            let output = root.appending(relativePath)
            let url = URL(fileURLWithPath: output.string)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try contents.write(to: url, options: .atomic)
        }
    }

    private static func documentsMatch(
        _ documents: [String: Data],
        under root: FilePath
    ) -> Bool {
        documents.allSatisfy { relativePath, expected in
            (try? read(root.appending(relativePath))) == expected
        }
    }

    private static func read(_ path: FilePath) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path.string))
        } catch {
            throw SkillDocumentationFailure.unreadable(path, error)
        }
    }

    private static func utf8(_ data: Data, label: String) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw SkillDocumentationFailure.invalid("\(label) is not valid UTF-8")
        }
        return value
    }

    private static func runGit(_ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw SkillDocumentationFailure.git("could not launch git: \(error)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SkillDocumentationFailure.git(
                message.isEmpty ? "git exited with status \(process.terminationStatus)" : message)
        }
        return data
    }
}

enum SkillDocumentationFailure: LocalizedError {
    case git(String)
    case invalid(String)
    case outOfDate(FilePath)
    case upstreamOutOfDate(checkedInRevision: String, upstreamRevision: String)
    case unreadable(FilePath, any Error)

    var errorDescription: String? {
        switch self {
        case .git(let message):
            "skill synchronization failed: \(message)"
        case .invalid(let message):
            message
        case .outOfDate(let path):
            "checked-in skill file is out of date: \(path)"
        case .upstreamOutOfDate(let checkedInRevision, let upstreamRevision):
            "swift-cxx-interop is out of date: checked-in Swift.org revision \(checkedInRevision), latest revision \(upstreamRevision); run `collider skill sync swift-cxx-interop`"
        case .unreadable(let path, let error):
            "could not read managed skill file \(path): \(error)"
        }
    }
}
