import Foundation
import Testing

/// The project does not use filesystem-synchronised groups, so a test file added on disk but not to
/// the test target compiles nowhere and its tests never run. These tests read `project.pbxproj`.
struct TestTargetMembershipTests {
    private enum MembershipError: Error {
        case targetNotFound(String)
        case sourcesPhaseNotFound(String)
    }

    private static let targetName = "ScribermanTests"

    @Test(.tags(.sourceLint))
    func everyTestFileIsInTheTestTarget() throws {
        let missing = try Self.missingFiles(project: Self.projectSource(), fileNames: Self.testFileNames())
        #expect(missing.isEmpty, "Missing from \(Self.targetName): \(missing.joined(separator: ", "))")
    }

    @Test(.tags(.sourceLint))
    func removedSourcesEntryIsReportedByName() throws {
        let probe = "TranscriptRowTests.swift"
        let edited = try Self.projectSource()
            .components(separatedBy: "\n")
            .filter { !$0.hasSuffix("/* \(probe) in Sources */,") }
            .joined(separator: "\n")

        let missing = try Self.missingFiles(project: edited, fileNames: Self.testFileNames())

        #expect(missing == [probe])
    }

    @Test(.tags(.sourceLint))
    func unknownTargetIsAnError() throws {
        let project = try Self.projectSource()
        #expect(throws: MembershipError.self) {
            try Self.sourceNames(ofTarget: "NoSuchTarget", in: project)
        }
    }

    // MARK: - Helpers

    private static var testsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    private static func projectSource() throws -> String {
        let projectURL = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scriberman.xcodeproj/project.pbxproj")
        return try String(contentsOf: projectURL, encoding: .utf8)
    }

    private static func testFileNames() throws -> [String] {
        let enumerator = FileManager.default.enumerator(at: testsDirectory, includingPropertiesForKeys: nil)
        var names: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" {
                names.append(url.lastPathComponent)
            }
        }
        return names.sorted()
    }

    private static func missingFiles(project: String, fileNames: [String]) throws -> [String] {
        let registered = Set(try sourceNames(ofTarget: targetName, in: project))
        return fileNames.filter { !registered.contains($0) }
    }

    /// The file names in the named native target's Sources build phase.
    private static func sourceNames(ofTarget target: String, in project: String) throws -> [String] {
        let lines = project.components(separatedBy: "\n")
        let blockEnd = "\t\t};"

        guard let targetStart = lines.indices.first(where: { index in
            lines[index].hasSuffix("/* \(target) */ = {")
                && lines.indices.contains(index + 1)
                && lines[index + 1].contains("isa = PBXNativeTarget;")
        }) else {
            throw MembershipError.targetNotFound(target)
        }

        var phaseID: String?
        for line in lines[targetStart...] {
            if line == blockEnd { break }
            if line.hasSuffix("/* Sources */,") {
                phaseID = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first
                break
            }
        }
        guard let phaseID,
              let phaseStart = lines.firstIndex(of: "\t\t\(phaseID) /* Sources */ = {")
        else {
            throw MembershipError.sourcesPhaseNotFound(target)
        }

        var names: [String] = []
        for line in lines[(phaseStart + 1)...] {
            if line == blockEnd { break }
            guard let open = line.range(of: "/* "),
                  let close = line.range(of: " in Sources */,", options: .backwards)
            else { continue }
            names.append(String(line[open.upperBound..<close.lowerBound]))
        }
        return names
    }
}
