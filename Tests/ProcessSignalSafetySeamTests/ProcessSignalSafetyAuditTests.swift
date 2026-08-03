import Foundation
import Testing

/// Inventories each executable-source process-control call site and requires an
/// explicit scope disposition. A product-only disposition is not a safety
/// approval; it records that Condition A lacks authority to alter that path.
struct ProcessSignalSafetyAuditTests {
    private enum Disposition: String, Equatable {
        case guardedConditionA
        case productOutsideConditionA
        case vendoredTemplateOutsideConditionA
    }

    private enum Primitive: String, Hashable {
        case posixSignal
        case processTermination
        case nodeSignal
        case processInterrupt
        case processGroupSignal
        case threadSignal
        case raiseSignal
        case broadMatcher
        case shellSignal
        case watchdogSignalBoundary
    }

    private struct CallSite: Hashable {
        let relativePath: String
        let line: Int
        let primitive: Primitive
        /// Distinguishes multiple process-control invocations of one kind on
        /// the same source line. Adding a second call then needs a second
        /// explicit disposition instead of collapsing into a file-level pass.
        let occurrence: Int = 1
    }

    @Test func everyExecutableProcessControlCallSiteHasAnExplicitDisposition() throws {
        let discovered = try discoveredProcessControlCallSites()
        #expect(Set(discovered) == Set(reviewedCallSites.keys))

        let guardedCallSites = Set(reviewedCallSites.compactMap { callSite, disposition in
            disposition == .guardedConditionA ? callSite : nil
        })
        #expect(guardedCallSites == Set(guardRationales.keys))
        #expect(guardRationales.values.allSatisfy { $0.isEmpty == false })

        let guarded = reviewedCallSites.filter { $0.value == .guardedConditionA }.map(\.key)
        #expect(guarded.contains(.init(
            relativePath: "Sources/WikiFSCore/Core/AsyncProcessRunner.swift",
            line: 110,
            primitive: .processTermination)))
        #expect(guarded.contains(.init(
            relativePath: "Sources/DynamicRendererPRSeriesAudit/main.swift",
            line: 201,
            primitive: .posixSignal)))
        #expect(guarded.contains(.init(
            relativePath: "scripts/lib/test-watchdog-process-control.sh",
            line: 85,
            primitive: .shellSignal)))
    }

    @Test func scannerRecognizesMultilineAbsoluteShellAndWatchdogBoundaryForms() {
        let killName = "kil" + "l"
        let watchdogSender = "watchdog" + "_send_signal"
        let source = "/bin/" + killName + " \\\nTERM 42\n"
            + watchdogSender + " TERM 42\n"
            + "proc.\n" + killName + "(TERM)\n"
        let callSites = processControlCallSites(in: source, relativePath: "Fixtures/process-control.sh")

        #expect(callSites.contains(.init(
            relativePath: "Fixtures/process-control.sh",
            line: 1,
            primitive: .shellSignal)))
        #expect(callSites.contains(.init(
            relativePath: "Fixtures/process-control.sh",
            line: 3,
            primitive: .watchdogSignalBoundary)))
        #expect(callSites.contains(.init(
            relativePath: "Fixtures/process-control.sh",
            line: 4,
            primitive: .nodeSignal)))
    }

    @Test func sourceEnumerationIncludesObjectiveCProcessHelperSources() throws {
        let paths = try repositoryExecutableSourceFiles(root: repositoryRoot())
        #expect(paths.contains("Sources/PodcastTokenHelper/main.m"))
    }

    @Test func conditionAHelpersUseTheInjectableNonSignalingBoundary() throws {
        let root = repositoryRoot()
        let makefile = try String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8)
        let watchdog = try String(contentsOf: root.appendingPathComponent("scripts/test-with-watchdog.sh"), encoding: .utf8)
        let watchdogBoundary = try String(contentsOf: root.appendingPathComponent("scripts/lib/test-watchdog-process-control.sh"), encoding: .utf8)
        let watchdogTests = try String(contentsOf: root.appendingPathComponent("scripts/tests/test-test-with-watchdog-process-control.sh"), encoding: .utf8)
        let archiveCleanup = try String(contentsOf: root.appendingPathComponent("scripts/paseo-archive-cleanup.sh"), encoding: .utf8)
        let runnerTests = try String(contentsOf: root.appendingPathComponent("Tests/WikiFSTests/AsyncProcessRunnerTests.swift"), encoding: .utf8)
        let auditRunnerTests = try String(contentsOf: root.appendingPathComponent("Tests/DynamicRendererPRSeriesAuditTests/AuditModelTests.swift"), encoding: .utf8)
        let pdfRegistryTests = try String(contentsOf: root.appendingPathComponent("Tests/WikiFSAppTests/PdfExtractionServiceTests.swift"), encoding: .utf8)
        let coreRunner = try String(contentsOf: root.appendingPathComponent("Sources/WikiFSCore/Core/AsyncProcessRunner.swift"), encoding: .utf8)
        let auditRunner = try String(contentsOf: root.appendingPathComponent("Sources/DynamicRendererPRSeriesAudit/main.swift"), encoding: .utf8)

        let broadKillTool = "p" + "kill"
        let rawKillCall = "kil" + "l("
        #expect(makefile.contains("[s]wiftpm-testing-helper") == false)
        let watchdogSender = "watchdog" + "_send_signal"
        let watchdogWrapper = "watchdog" + "_signal_verified_child"
        #expect(watchdog.contains("watchdog_capture_identity"))
        #expect(watchdog.contains(watchdogWrapper))
        #expect(watchdog.contains("watchdog_has_precise_identity_observer"))
        let availabilityCheck = try #require(watchdog.range(of: "watchdog_has_precise_identity_observer"))
        let testLaunch = try #require(watchdog.range(of: "swift test -v"))
        let postLaunchRefusal = try #require(watchdog.range(of: "post-launch process identity unavailable"))
        #expect(availabilityCheck.lowerBound < testLaunch.lowerBound)
        #expect(testLaunch.lowerBound < postLaunchRefusal.lowerBound)
        #expect(watchdog.contains("jobs -pr | grep -Fx -- \"$TEST_PID\""))
        #expect(watchdog.contains("The child already completed, so this wait is bounded."))
        #expect(watchdog.contains("wait \"$TEST_PID\""))
        #expect(watchdog.contains("child identity is no longer verified"))
        #expect(watchdog.contains(rawKillCall) == false)
        #expect(watchdogBoundary.contains("watchdog_observe_process"))
        #expect(watchdogBoundary.contains(watchdogSender))
        #expect(watchdogBoundary.contains("watchdog_is_verified_direct_child"))
        #expect(watchdogTests.contains(rawKillCall) == false)
        #expect(watchdogTests.contains(watchdogSender + "()"))
        #expect(watchdogTests.contains("stale-or-reused"))
        #expect(watchdogTests.contains("non-child"))
        #expect(watchdogTests.contains("unavailable-identity"))
        #expect(watchdog.contains(broadKillTool) == false)
        #expect(archiveCleanup.contains("same-pgid-") == false)
        #expect(archiveCleanup.contains("ancestor-of-") == false)
        #expect(archiveCleanup.contains("refusing to signal snapshot candidates"))
        #expect(archiveCleanup.contains("argv0_of") == false)
        #expect(archiveCleanup.contains("basename_of") == false)
        #expect(archiveCleanup.contains("if ! awk"))
        #expect(archiveCleanup.contains("failed to classify process snapshot"))
        #expect(archiveCleanup.contains("if ! process_snapshot"))
        #expect(archiveCleanup.contains("failed to capture process snapshot"))
        #expect(runnerTests.contains(rawKillCall) == false)
        #expect(runnerTests.contains("setsid") == false)
        #expect(runnerTests.contains("requestTermination: { _ in }"))
        #expect(runnerTests.contains("sendSignal: signals.recordSignal"))
        #expect(auditRunnerTests.contains("requestTermination: control.requestTermination"))
        #expect(auditRunnerTests.contains("sendSignal: control.sendSignal"))
        #expect(pdfRegistryTests.contains("NonSignalingProcessControl"))
        #expect(pdfRegistryTests.contains("requestTermination: control.requestTermination"))
        #expect(pdfRegistryTests.contains(rawKillCall) == false)
        #expect(coreRunner.contains("ProcessIdentityObservation.observe"))
        #expect(coreRunner.contains("ProcessSignalSafety.verify("))
        #expect(coreRunner.contains("ProcessSignalSafety.signal("))
        #expect(coreRunner.contains("ObjectIdentifier") == false)
        #expect(auditRunner.contains("ProcessIdentityObservation.observe"))
        #expect(auditRunner.contains("ProcessSignalSafety.verify("))
        #expect(auditRunner.contains("ProcessSignalSafety.signal("))
    }

    private var reviewedCallSites: [CallSite: Disposition] {
        [
            .init(relativePath: "Makefile", line: 568, primitive: .broadMatcher): .productOutsideConditionA,
            .init(relativePath: "Makefile", line: 569, primitive: .broadMatcher): .productOutsideConditionA,
            .init(relativePath: "Makefile", line: 576, primitive: .broadMatcher): .productOutsideConditionA,
            .init(relativePath: "Makefile", line: 577, primitive: .broadMatcher): .productOutsideConditionA,
            .init(relativePath: "docs/skills/macos-spm-app-packaging/assets/templates/compile_and_run.sh", line: 30, primitive: .broadMatcher): .vendoredTemplateOutsideConditionA,
            .init(relativePath: "docs/skills/macos-spm-app-packaging/assets/templates/compile_and_run.sh", line: 31, primitive: .broadMatcher): .vendoredTemplateOutsideConditionA,
            .init(relativePath: "docs/skills/macos-spm-app-packaging/assets/templates/compile_and_run.sh", line: 32, primitive: .broadMatcher): .vendoredTemplateOutsideConditionA,
            .init(relativePath: "docs/skills/macos-spm-app-packaging/assets/templates/compile_and_run.sh", line: 33, primitive: .broadMatcher): .vendoredTemplateOutsideConditionA,
            .init(relativePath: "docs/skills/macos-spm-app-packaging/assets/templates/launch.sh", line: 10, primitive: .broadMatcher, occurrence: 1): .vendoredTemplateOutsideConditionA,
            .init(relativePath: "docs/skills/macos-spm-app-packaging/assets/templates/launch.sh", line: 10, primitive: .broadMatcher, occurrence: 2): .vendoredTemplateOutsideConditionA,
            .init(relativePath: "Sources/DynamicRendererPRSeriesAudit/main.swift", line: 194, primitive: .processTermination): .guardedConditionA,
            .init(relativePath: "Sources/DynamicRendererPRSeriesAudit/main.swift", line: 201, primitive: .posixSignal): .guardedConditionA,
            .init(relativePath: "Sources/WikiFS/Sources/DefuddleExtractionService.swift", line: 178, primitive: .processTermination): .productOutsideConditionA,
            .init(relativePath: "Sources/WikiFS/Sources/DefuddleExtractionService.swift", line: 362, primitive: .processTermination): .productOutsideConditionA,
            .init(relativePath: "Sources/WikiFS/Window/MenuBarItemController.swift", line: 389, primitive: .processTermination): .productOutsideConditionA,
            .init(relativePath: "Sources/WikiFSCore/Core/AsyncProcessRunner.swift", line: 110, primitive: .processTermination): .guardedConditionA,
            .init(relativePath: "Sources/WikiFSCore/Core/AsyncProcessRunner.swift", line: 117, primitive: .posixSignal): .guardedConditionA,
            .init(relativePath: "Sources/WikiFSCore/Integrations/TranscriptSubprocess.swift", line: 67, primitive: .posixSignal): .productOutsideConditionA,
            .init(relativePath: "Sources/WikiFSCore/Integrations/TranscriptSubprocess.swift", line: 68, primitive: .posixSignal): .productOutsideConditionA,
            .init(relativePath: "Sources/WikiFSEngine/ACPBackend.swift", line: 1226, primitive: .processTermination): .productOutsideConditionA,
            .init(relativePath: "Sources/WikiFSEngine/ACPBackend.swift", line: 1366, primitive: .posixSignal): .productOutsideConditionA,
            .init(relativePath: "Sources/WikiFSEngine/ACPBackend.swift", line: 1411, primitive: .processTermination): .productOutsideConditionA,
            .init(relativePath: "Sources/WikiFSEngine/ACPBackend.swift", line: 1418, primitive: .processTermination): .productOutsideConditionA,
            .init(relativePath: "Sources/WikiFSEngine/ACPProviderModelProbe.swift", line: 393, primitive: .processTermination): .productOutsideConditionA,
            .init(relativePath: "Sources/WikiFSEngine/PdfExtractionService.swift", line: 25, primitive: .processTermination): .productOutsideConditionA,
            .init(relativePath: "Sources/WikiFSEngine/PdfExtractionService.swift", line: 191, primitive: .processTermination): .productOutsideConditionA,
            .init(relativePath: "Sources/WikiFSEngine/PdfExtractionService.swift", line: 484, primitive: .processTermination): .productOutsideConditionA,
            .init(relativePath: "scripts/lib/test-watchdog-process-control.sh", line: 75, primitive: .watchdogSignalBoundary): .guardedConditionA,
            .init(relativePath: "scripts/lib/test-watchdog-process-control.sh", line: 85, primitive: .shellSignal): .guardedConditionA,
            .init(relativePath: "scripts/lib/test-watchdog-process-control.sh", line: 88, primitive: .watchdogSignalBoundary): .guardedConditionA,
            .init(relativePath: "scripts/lib/test-watchdog-process-control.sh", line: 97, primitive: .watchdogSignalBoundary): .guardedConditionA,
            .init(relativePath: "scripts/test-with-watchdog.sh", line: 77, primitive: .watchdogSignalBoundary): .guardedConditionA,
            .init(relativePath: "scripts/test-with-watchdog.sh", line: 81, primitive: .watchdogSignalBoundary): .guardedConditionA,
            .init(relativePath: "scripts/tests/test-test-with-watchdog-process-control.sh", line: 24, primitive: .watchdogSignalBoundary): .guardedConditionA,
            .init(relativePath: "scripts/tests/test-test-with-watchdog-process-control.sh", line: 33, primitive: .watchdogSignalBoundary): .guardedConditionA,
            .init(relativePath: "scripts/tests/test-test-with-watchdog-process-control.sh", line: 46, primitive: .watchdogSignalBoundary): .guardedConditionA,
            .init(relativePath: "scripts/tests/test-test-with-watchdog-process-control.sh", line: 78, primitive: .watchdogSignalBoundary): .guardedConditionA,
            .init(relativePath: "tools/defuddle/defuddle", line: 1171, primitive: .nodeSignal): .productOutsideConditionA,
        ]
    }

    private var guardRationales: [CallSite: String] {
        [
            .init(relativePath: "Sources/DynamicRendererPRSeriesAudit/main.swift", line: 194, primitive: .processTermination): "launch identity and fresh observation before termination seam",
            .init(relativePath: "Sources/DynamicRendererPRSeriesAudit/main.swift", line: 201, primitive: .posixSignal): "shared ProcessSignalSafety verifies fresh identity before syscall seam",
            .init(relativePath: "Sources/WikiFSCore/Core/AsyncProcessRunner.swift", line: 110, primitive: .processTermination): "launch identity and fresh observation before cancellation seam",
            .init(relativePath: "Sources/WikiFSCore/Core/AsyncProcessRunner.swift", line: 117, primitive: .posixSignal): "shared ProcessSignalSafety verifies fresh identity before syscall seam",
            .init(relativePath: "scripts/lib/test-watchdog-process-control.sh", line: 75, primitive: .watchdogSignalBoundary): "sourceable sender independently revalidates exact direct-child identity before builtin signal",
            .init(relativePath: "scripts/lib/test-watchdog-process-control.sh", line: 85, primitive: .shellSignal): "sender independently revalidates exact direct-child identity before builtin signal",
            .init(relativePath: "scripts/lib/test-watchdog-process-control.sh", line: 88, primitive: .watchdogSignalBoundary): "sourceable wrapper delegates only to independently verifying sender",
            .init(relativePath: "scripts/lib/test-watchdog-process-control.sh", line: 97, primitive: .watchdogSignalBoundary): "sourceable wrapper call passes expected identity to independently verifying sender",
            .init(relativePath: "scripts/test-with-watchdog.sh", line: 77, primitive: .watchdogSignalBoundary): "main wrapper reaches sender only after launch identity and fresh observation",
            .init(relativePath: "scripts/test-with-watchdog.sh", line: 81, primitive: .watchdogSignalBoundary): "main wrapper reaches sender only after launch identity and fresh observation",
            .init(relativePath: "scripts/tests/test-test-with-watchdog-process-control.sh", line: 24, primitive: .watchdogSignalBoundary): "direct production sender refusal test uses unavailable observer and reaches no raw signal",
            .init(relativePath: "scripts/tests/test-test-with-watchdog-process-control.sh", line: 33, primitive: .watchdogSignalBoundary): "test-only fake sender is non-signaling",
            .init(relativePath: "scripts/tests/test-test-with-watchdog-process-control.sh", line: 46, primitive: .watchdogSignalBoundary): "test-only wrapper exercise reaches a non-signaling fake sender",
            .init(relativePath: "scripts/tests/test-test-with-watchdog-process-control.sh", line: 78, primitive: .watchdogSignalBoundary): "test-only matching case reaches a non-signaling fake sender",
        ]
    }

    private func discoveredProcessControlCallSites() throws -> [CallSite] {
        let root = repositoryRoot()
        return try repositoryExecutableSourceFiles(root: root).flatMap { relativePath in
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            return processControlCallSites(in: source, relativePath: relativePath)
        }
    }

    private func processControlCallSites(in source: String, relativePath: String) -> [CallSite] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.indices.flatMap { index in
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard isExecutableLine(line) else { return [] }
            let window = detectionWindow(lines: lines, startingAt: index)
            let firstLineLength = line.utf16.count
            return processControlPatterns.flatMap { primitive, expression in
                expression.matches(in: window, range: NSRange(window.startIndex..., in: window))
                    .filter { $0.range.location < firstLineLength }
                    .enumerated()
                    .map { occurrence, _ in
                        .init(
                            relativePath: relativePath,
                            line: index + 1,
                            primitive: primitive,
                            occurrence: occurrence + 1)
                    }
            }
        }
    }

    private func detectionWindow(lines: [String], startingAt index: Int) -> String {
        let endIndex = min(index + 2, lines.index(before: lines.endIndex))
        return lines[index...endIndex].joined(separator: " ")
    }

    private func repositoryExecutableSourceFiles(root: URL) throws -> [String] {
        let excludedDirectories: Set<String> = [".build", ".git", "plans", "progress", "tmp"]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        var paths: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let components = relativePath.split(separator: "/").map(String.init)
            if components.contains(where: { excludedDirectories.contains($0) }) {
                if url.hasDirectoryPath { enumerator?.skipDescendants() }
                continue
            }
            guard url.isFileURL else { continue }
            let isTool = components.first == "tools"
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let nativeSourceExtensions: Set<String> = ["c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm", "swift"]
            let toolSourceExtensions: Set<String> = ["cjs", "js", "mjs", "py", "sh", "swift", "ts"]
            let isToolSource = isTool && (toolSourceExtensions.contains(url.pathExtension) || url.pathExtension.isEmpty)
            if nativeSourceExtensions.contains(url.pathExtension) || url.pathExtension == "sh" || url.lastPathComponent == "Makefile" || isToolSource {
                paths.append(relativePath)
            }
        }
        return paths.sorted()
    }

    private func isExecutableLine(_ line: String) -> Bool {
        line.hasPrefix("//") == false
            && line.hasPrefix("#") == false
            && line.hasPrefix("/*") == false
            && line.hasPrefix("*") == false
    }

    private var processControlPatterns: [(Primitive, NSRegularExpression)] {
        let killName = "kil" + "l"
        let terminateName = "ter" + "minate"
        let interruptName = "inter" + "rupt"
        let groupName = "kill" + "pg"
        let threadName = "pthread_" + "kill"
        let broadName = "p" + "kill"
        let allName = "kill" + "all"
        let watchdogSender = "watchdog" + "_send_signal"
        let watchdogWrapper = "watchdog" + "_signal_verified_child"
        return [
            (.posixSignal, expression("(?<![A-Za-z0-9_.])" + killName + "\\s*\\(")),
            (.processTermination, expression("\\.\\s*" + terminateName + "\\s*\\(")),
            (.nodeSignal, expression("\\.\\s*" + killName + "\\s*\\(")),
            (.processInterrupt, expression("\\." + interruptName + "\\s*\\(")),
            (.processGroupSignal, expression("(?<![A-Za-z0-9_.])" + groupName + "\\s*\\(")),
            (.threadSignal, expression("(?<![A-Za-z0-9_.])" + threadName + "\\s*\\(")),
            (.raiseSignal, expression("(?<![A-Za-z0-9_.])raise\\s*\\(")),
            (.broadMatcher, expression("\\b(" + broadName + "|" + allName + ")\\b")),
            (.shellSignal, expression("(^|[;|&[:space:]])((command|builtin)[[:space:]]+)?(/([A-Za-z0-9_.-]+/)*)?" + killName + "(?=[[:space:]\\\\]|$)")),
            (.watchdogSignalBoundary, expression("(?<![A-Za-z0-9_])(" + watchdogSender + "|" + watchdogWrapper + ")\\b")),
        ]
    }

    private func expression(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
