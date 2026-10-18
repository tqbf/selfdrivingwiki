// pattern: Imperative Shell

import Foundation
import Testing
import WikiFSTypes
import WikiFSEngine
#if canImport(Darwin)
import Darwin
#endif

/// Gives opt-in ACP smoke tests a process group they can synchronously reap,
/// including descendants left behind when the SDK handshake wedges.
final class ACPTestProcessGroup: @unchecked Sendable {
    private let markerURL: URL
    private let readyURL: URL
    let wrapperURL: URL
    let perlURL = URL(fileURLWithPath: "/usr/bin/perl")
    private let identityLock = NSLock()
    private var pinnedIdentity: ProcessSignalSafety.Identity?
    private var isCleaningUp = false
    private let identityTimer: DispatchSourceTimer
    private var cleanupWatchdog: DispatchWorkItem?
    init(directory: URL) throws {
        markerURL = directory.appendingPathComponent("agent-process-group")
        readyURL = directory.appendingPathComponent("agent-process-group-ready")
        guard let wrapperURL = Bundle.module.url(
            forResource: "ACPTestProcessGroupWrapper", withExtension: "pl") else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.wrapperURL = wrapperURL

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        identityTimer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.pinIdentityAndReleaseWrapper() }
        timer.resume()
    }

    func setRealAgent(_ path: String) -> [String: String] {
        [
            "ACP_TEST_PROCESS_MARKER": markerURL.path,
            "ACP_TEST_PROCESS_READY": readyURL.path,
            "ACP_TEST_REAL_AGENT": path,
        ]
    }

    func wrapperArguments(for realAgentArguments: [String]) -> [String] {
        [wrapperURL.path] + realAgentArguments
    }

    func serializedWrapperArguments(for realAgentArguments: [String]) -> String {
        wrapperArguments(for: realAgentArguments).map { argument in
            "\"" + argument
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: " ")
    }

    /// Safe to call from `defer`: it does not wait for async SDK teardown.
    func killGroup() {
        identityTimer.cancel()
        identityLock.lock()
        isCleaningUp = true
        let watchdog = cleanupWatchdog
        cleanupWatchdog = nil
        var expectedIdentity = pinnedIdentity
        identityLock.unlock()
        watchdog?.cancel()
        guard let rawPID = try? String(contentsOf: markerURL, encoding: .utf8),
              let processGroupID = ProcessSignalSafety.PositivePID(pidFileContents: rawPID)?.rawValue else { return }
        guard let positivePID = ProcessSignalSafety.PositivePID(rawValue: processGroupID) else {
            DebugLog.agent("ACP smoke cleanup refused group \(processGroupID): leader identity unavailable or changed")
            return
        }
        let observedIdentity = ProcessIdentityObservation.observe(processID: positivePID)
        if expectedIdentity == nil,
           let observedIdentity,
           observedIdentity.parentProcessID.rawValue == getpid() {
            expectedIdentity = observedIdentity
            identityLock.lock()
            pinnedIdentity = observedIdentity
            identityLock.unlock()
        }
        guard let expectedIdentity else {
            DebugLog.agent("ACP smoke cleanup refused group \(processGroupID): no pinned identity")
            return
        }
        // A process group can outlive its leader. The kernel keeps the PGID
        // reserved while members remain. If the original PID has exited or
        // been reused, the pinned PGID can still name only this live group;
        // an unrelated group cannot take its id while this group exists.
        let verifiedLeader = observedIdentity == expectedIdentity
            && getpgid(processGroupID) == processGroupID
        if let observedIdentity, observedIdentity != expectedIdentity {
            DebugLog.agent("ACP smoke cleanup found a reused leader PID \(processGroupID); checking the pinned PGID")
        }
        guard verifiedLeader || kill(-processGroupID, 0) == 0 else { return }
        if kill(-processGroupID, SIGKILL) != 0, errno != ESRCH {
            DebugLog.agent("Could not kill ACP smoke process group \(processGroupID): errno \(errno)")
        }
    }

    func processGroupID() -> Int32? {
        guard let rawPID = try? String(contentsOf: markerURL, encoding: .utf8) else { return nil }
        return ProcessSignalSafety.PositivePID(pidFileContents: rawPID)?.rawValue
    }

    private func pinIdentityAndReleaseWrapper() {
        guard let rawPID = try? String(contentsOf: markerURL, encoding: .utf8),
              let processID = ProcessSignalSafety.PositivePID(pidFileContents: rawPID),
              getpgid(processID.rawValue) == processID.rawValue,
              let identity = ProcessIdentityObservation.observe(processID: processID),
              identity.parentProcessID.rawValue == getpid() else { return }
        identityLock.lock()
        guard !isCleaningUp else {
            identityLock.unlock()
            return
        }
        if pinnedIdentity == nil { pinnedIdentity = identity }
        let watchdog = DispatchWorkItem { [self] in killGroup() }
        cleanupWatchdog = watchdog
        identityLock.unlock()
        do {
            try Data().write(to: readyURL, options: .atomic)
        } catch {
            DebugLog.agent("Could not release ACP smoke process group wrapper: \(error.localizedDescription)")
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(240), execute: watchdog)
        identityTimer.cancel()
    }
}
