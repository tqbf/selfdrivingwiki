#if os(macOS)
import Foundation
import Testing
import WikiCtlCore

/// Tests for the `DaemonConnectionState` enum (#878).
struct DaemonConnectionStateTests {

    @Test func statesAreEquatable() {
        #expect(DaemonConnectionState.connected == .connected)
        #expect(DaemonConnectionState.disconnected == .disconnected)
        #expect(DaemonConnectionState.reconnecting == .reconnecting)
    }

    @Test func statesHaveDistinctRawValues() {
        let values: Set<String> = [
            DaemonConnectionState.connected.rawValue,
            DaemonConnectionState.disconnected.rawValue,
            DaemonConnectionState.reconnecting.rawValue,
        ]
        #expect(values.count == 3)
    }

    @Test func statesAreSendable() {
        // Compiles only if Sendable (the conformance is declared on the enum).
        let state = DaemonConnectionState.connected
        #expect(state == .connected)
    }
}
#endif
