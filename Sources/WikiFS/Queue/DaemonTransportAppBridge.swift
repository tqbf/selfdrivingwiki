#if os(macOS)
import Foundation
import WikiCtlCore
import WikiFSEngine

actor DaemonTransportAppBridge {
    private enum Registration {
        case provisional(WikiDaemonConnection)
        case connected(WikiDaemonConnection)

        var connection: WikiDaemonConnection {
            switch self {
            case .provisional(let connection), .connected(let connection): connection
            }
        }
    }

    typealias ConnectionFactory = @Sendable () throws -> WikiDaemonConnection

    private let connect: ConnectionFactory
    private var registrations: [DaemonTransportCandidateID: Registration] = [:]
    private var stopped = false

    init(connect: @escaping ConnectionFactory = { try WikiDaemonConnection.connect() }) {
        self.connect = connect
    }

    nonisolated var connectionFactory: DaemonTransportConnectionFactory {
        DaemonTransportConnectionFactory { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.makeCandidate(id: id)
        }
    }

    func resolve(_ id: DaemonTransportCandidateID) -> WikiDaemonConnection? {
        guard !stopped else { return nil }
        return registrations[id]?.connection
    }

    func markConnected(_ id: DaemonTransportCandidateID) -> Bool {
        guard !stopped,
              case .provisional(let connection) = registrations[id] else { return false }
        for (otherID, registration) in registrations where otherID != id {
            registration.connection.invalidate()
            registrations.removeValue(forKey: otherID)
        }
        registrations[id] = .connected(connection)
        return true
    }

    func remove(_ id: DaemonTransportCandidateID, invalidate: Bool = true) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        if invalidate { registration.connection.invalidate() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        let connections = registrations.values.map(\.connection)
        registrations.removeAll()
        for connection in connections { connection.invalidate() }
    }

    private func makeCandidate(
        id: DaemonTransportCandidateID
    ) throws -> any DaemonTransportConnection {
        guard !stopped else { throw CancellationError() }
        let connection = try connect()
        guard !Task.isCancelled, !stopped else {
            connection.invalidate()
            throw CancellationError()
        }
        registrations[id] = .provisional(connection)
        return WikiDaemonTransportConnection(
            connection: connection,
            candidateID: id,
            onInvalidate: { [weak self] candidateID in
                Task { await self?.remove(candidateID, invalidate: false) }
            })
    }
}

// All fields are immutable. `WikiDaemonConnection` supports concurrent XPC proxy access.
// swiftlint:disable:next unchecked_sendable
private final class WikiDaemonTransportConnection: DaemonTransportConnection, @unchecked Sendable {
    private let connection: WikiDaemonConnection
    private let candidateID: DaemonTransportCandidateID
    private let onInvalidate: @Sendable (DaemonTransportCandidateID) -> Void

    init(
        connection: WikiDaemonConnection,
        candidateID: DaemonTransportCandidateID,
        onInvalidate: @escaping @Sendable (DaemonTransportCandidateID) -> Void
    ) {
        self.connection = connection
        self.candidateID = candidateID
        self.onInvalidate = onInvalidate
    }

    func healthCheck(timeout: TimeInterval) async -> Bool {
        await connection.healthCheck(timeout: timeout)
    }

    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        connection.setInvalidationHandler(handler)
    }

    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
        connection.setInterruptionHandler(handler)
    }

    func invalidate() {
        connection.invalidate()
        onInvalidate(candidateID)
    }
}
#endif
