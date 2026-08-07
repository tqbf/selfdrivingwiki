#if os(macOS)
import CryptoKit
import Darwin
import Dispatch
import Foundation
import Network
import Security

/// pattern: Imperative Shell
///
/// Test-only loopback receivers for hosted WebKit isolation controls. The
/// HTTP sockets bind `127.0.0.1:0` and the WebSocket listener binds the same
/// loopback address with TLS. Every instance receives an OS-assigned port; an
/// exact, unpredictable token in the request target identifies its traffic.
@MainActor
final class RendererLoopbackObservationServer {
    enum Transport: Equatable {
        case http
        case webSocket
    }

    struct Observation: Equatable {
        let transport: Transport
        let token: String
    }

    enum ServerError: LocalizedError {
        case socketCreation(errno: Int32)
        case socketOption(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
        case address(errno: Int32)
        case keychainIdentity(status: OSStatus)
        case trustedIdentityMissing
        case secureListener(String)
        case timeout(description: String)
        case stopped

        var errorDescription: String? {
            switch self {
            case let .socketCreation(errno): "failed to create loopback socket: \(String(cString: strerror(errno)))"
            case let .socketOption(errno): "failed to configure loopback socket: \(String(cString: strerror(errno)))"
            case let .bind(errno): "failed to bind loopback socket: \(String(cString: strerror(errno)))"
            case let .listen(errno): "failed to listen on loopback socket: \(String(cString: strerror(errno)))"
            case let .address(errno): "failed to read loopback socket address: \(String(cString: strerror(errno)))"
            case let .keychainIdentity(status): "failed to resolve trusted loopback TLS identity: \(Self.keychainErrorDescription(for: status))"
            case .trustedIdentityMissing: "failed to resolve trusted loopback TLS identity: expected mkcert identity was not found in the login keychain"
            case let .secureListener(description): "failed to start trusted loopback TLS listener: \(description)"
            case let .timeout(description): "timed out waiting for \(description)"
            case .stopped: "loopback observation server stopped before observing traffic"
            }
        }

        private static func keychainErrorDescription(for status: OSStatus) -> String {
            SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        }
    }

    private enum Metrics {
        static let waitPollInterval: Duration = .milliseconds(10)
        static let defaultTimeout: Duration = .seconds(15)
        static let readBufferSize = 16 * 1024
        static let maximumHeaderBytes = 64 * 1024
    }

    let transport: Transport
    let observationToken: String

    var observationURL: URL? {
        guard let port else { return nil }
        switch transport {
        case .http:
            return URL(string: "http://127.0.0.1:\(port)/observe/\(observationToken)")
        case .webSocket:
            // Use the certificate's IPv4 loopback SAN. The listener owns the
            // IPv4 loopback endpoint explicitly.
            return URL(string: "wss://127.0.0.1:\(port)/observe/\(observationToken)")
        }
    }

    var documentURL: URL? {
        guard transport == .http, let port, hostedDocument != nil else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/document/\(observationToken)")
    }

    var diagnostics: String {
        let listenerState = secureListener.map { String(describing: $0.state) } ?? "none"
        return "transport=\(transport), port=\(port.map(String.init) ?? "none"), "
            + "listener=\(listenerState), secureConnections=\(secureConnections.count), "
            + "observed=\(observed != nil), lastConnectionEvent=\(lastConnectionEvent)"
    }

    /// The socket sources and their owner are both main-actor isolated. Using
    /// the main dispatch executor prevents a source callback from crossing into
    /// the actor while it is tearing down a live receiver.
    private let queue = DispatchQueue.main
    private var listenerFD: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private var secureListener: NWListener?
    private var secureConnections: [UUID: SecureConnection] = [:]
    private var port: UInt16?
    private var didStart = false
    private var didStop = false
    private var observed: Observation?
    private var lastConnectionEvent = "no loopback connection accepted"
    private var hostedDocument: String?

    init(protocol transport: Transport, observationToken: String = UUID().uuidString) throws {
        guard !observationToken.isEmpty else { throw ServerError.stopped }
        self.transport = transport
        self.observationToken = observationToken
    }

    /// Serves a real loopback document so WebKit establishes an HTTP document
    /// origin before the test asks it to open a WebSocket.
    func hostDocument(_ html: String) throws {
        guard transport == .http, !html.isEmpty else { throw ServerError.stopped }
        hostedDocument = html
    }

    /// Binds the OS-assigned listener and begins the asynchronous accept loop.
    func start(timeout: Duration = Metrics.defaultTimeout) async throws {
        guard !didStart else { return }
        guard !didStop else { throw ServerError.stopped }
        if transport == .webSocket {
            try await startSecureWebSocketListener(timeout: timeout)
            return
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketCreation(errno: errno) }
        listenerFD = fd

        var reuseAddress: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout.size(ofValue: reuseAddress))) == 0 else {
            closeListener()
            throw ServerError.socketOption(errno: errno)
        }
        guard setNonblocking(fd) else {
            let failure = errno
            closeListener()
            throw ServerError.socketOption(errno: failure)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let didBind = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0 else {
            let failure = errno
            closeListener()
            throw ServerError.bind(errno: failure)
        }
        guard listen(fd, SOMAXCONN) == 0 else {
            let failure = errno
            closeListener()
            throw ServerError.listen(errno: failure)
        }

        var assignedAddress = sockaddr_in()
        var assignedAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didReadAddress = withUnsafeMutablePointer(to: &assignedAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &assignedAddressLength)
            }
        }
        guard didReadAddress == 0 else {
            let failure = errno
            closeListener()
            throw ServerError.address(errno: failure)
        }
        port = UInt16(bigEndian: assignedAddress.sin_port)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptPendingConnections() }
        }
        source.setCancelHandler { }
        listenerSource = source
        didStart = true
        source.resume()

        try await waitFor("loopback listener readiness", timeout: timeout) { self.didStart && self.port != nil }
    }

    func waitForObservation(timeout: Duration = Metrics.defaultTimeout) async throws -> Observation {
        try await waitFor("\(transport) observation token \(observationToken) (\(lastConnectionEvent))", timeout: timeout) {
            self.observed != nil
        }
        guard let observed else { throw ServerError.stopped }
        return observed
    }

    /// Explicitly tears down listener and accepted connections. Safe to repeat.
    func stop() {
        guard !didStop else { return }
        didStop = true
        listenerSource?.cancel()
        listenerSource = nil
        secureListener?.cancel()
        secureListener = nil
        closeListener()
        let activeConnections = connections.values
        connections.removeAll()
        activeConnections.forEach { $0.stop() }
        let activeSecureConnections = secureConnections.values
        secureConnections.removeAll()
        activeSecureConnections.forEach { $0.stop() }
    }

    private func acceptPendingConnections() {
        guard !didStop, listenerFD >= 0 else { return }
        while true {
            let fd = accept(listenerFD, nil, nil)
            if fd < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            guard setNonblocking(fd) else {
                Darwin.close(fd)
                continue
            }
            lastConnectionEvent = "accepted a loopback connection"
            let connection = Connection(fd: fd, queue: queue) { [weak self] headers in
                self?.handle(headers: headers, connectionFD: fd)
            }
            connections[fd] = connection
            connection.start()
        }
    }

    private func startSecureWebSocketListener(timeout: Duration) async throws {
        let identity = try trustedLoopbackIdentity()
        let tlsOptions = NWProtocolTLS.Options()
        guard let networkIdentity = sec_identity_create(identity) else {
            throw ServerError.trustedIdentityMissing
        }
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, networkIdentity)
        let parameters = NWParameters(tls: tlsOptions, tcp: .init())
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            throw ServerError.secureListener(error.localizedDescription)
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handleSecureListenerState(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.acceptSecureWebSocketConnection(connection) }
        }
        secureListener = listener
        listener.start(queue: queue)
        try await waitFor("trusted loopback TLS listener readiness", timeout: timeout) {
            self.didStart && self.port != nil
        }
    }

    private func handleSecureListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let listenerPort = secureListener?.port else { return }
            port = listenerPort.rawValue
            didStart = true
        case let .failed(error):
            lastConnectionEvent = "trusted TLS listener failed: \(error.localizedDescription)"
        default:
            break
        }
    }

    private func acceptSecureWebSocketConnection(_ connection: NWConnection) {
        guard !didStop else {
            connection.cancel()
            return
        }
        lastConnectionEvent = "accepted a trusted loopback TLS connection"
        let connectionID = UUID()
        let observer = SecureConnection(connection: connection, queue: queue) { [weak self] headers in
            self?.handleSecureWebSocket(headers: headers, connectionID: connectionID)
        } onStop: { [weak self] in
            self?.secureConnections.removeValue(forKey: connectionID)
        }
        secureConnections[connectionID] = observer
        observer.start()
    }

    private func handleSecureWebSocket(headers: String, connectionID: UUID) {
        guard !didStop, let connection = secureConnections[connectionID] else { return }
        guard requestTarget(in: headers) == "/observe/\(observationToken)" else {
            lastConnectionEvent = "received a request for a different target"
            connection.stop()
            return
        }
        guard let key = header(named: "sec-websocket-key", in: headers),
              header(named: "upgrade", in: headers)?.lowercased() == "websocket",
              header(named: "connection", in: headers)?.lowercased().contains("upgrade") == true
        else {
            lastConnectionEvent = "rejected an incomplete WebSocket upgrade request: \(headerSummary(in: headers))"
            connection.stop()
            return
        }
        lastConnectionEvent = "received a valid trusted WebSocket upgrade request"
        let accept = Data(Insecure.SHA1.hash(data: Data("\(key)258EAFA5-E914-47DA-95CA-C5AB0DC85B11".utf8))).base64EncodedString()
        connection.send(response: Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)) { [weak self] in
            self?.recordObservation()
        }
    }

    private func handle(headers: String, connectionFD: Int32) {
        guard !didStop, let connection = connections[connectionFD] else { return }
        if transport == .http,
           requestTarget(in: headers) == "/document/\(observationToken)",
           let hostedDocument
        {
            let body = Data(hostedDocument.utf8)
            connection.send(response: Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body) { [weak self, weak connection] in
                connection?.stop()
                self?.connections.removeValue(forKey: connectionFD)
            }
            return
        }
        guard requestTarget(in: headers) == "/observe/\(observationToken)" else {
            lastConnectionEvent = "received a request for a different target"
            connection.stop()
            connections.removeValue(forKey: connectionFD)
            return
        }

        switch transport {
        case .http:
            lastConnectionEvent = "received the expected HTTP request"
            connection.send(response: Data("HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)) { [weak self, weak connection] in
                guard let self else {
                    connection?.stop()
                    return
                }
                self.recordObservation()
                connection?.stop()
                self.connections.removeValue(forKey: connectionFD)
            }
        case .webSocket:
            guard let key = header(named: "sec-websocket-key", in: headers),
                  header(named: "upgrade", in: headers)?.lowercased() == "websocket",
                  header(named: "connection", in: headers)?.lowercased().contains("upgrade") == true
            else {
                lastConnectionEvent = "rejected an incomplete WebSocket upgrade request"
                connection.stop()
                connections.removeValue(forKey: connectionFD)
                return
            }
            lastConnectionEvent = "received a valid WebSocket upgrade request"
            let accept = Data(Insecure.SHA1.hash(data: Data("\(key)258EAFA5-E914-47DA-95CA-C5AB0DC85B11".utf8))).base64EncodedString()
            connection.send(response: Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)) { [weak self] in
                self?.recordObservation()
            }
        }
    }

    private func recordObservation() {
        guard observed == nil, !didStop else { return }
        lastConnectionEvent = transport == .http ? "sent the HTTP response" : "sent the WebSocket upgrade response"
        observed = Observation(transport: transport, token: observationToken)
    }

    private func waitFor(_ description: String, timeout: Duration, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if didStop { throw ServerError.stopped }
            guard ContinuousClock.now < deadline else { throw ServerError.timeout(description: description) }
            try Task.checkCancellation()
            try await Task.sleep(for: Metrics.waitPollInterval)
        }
    }

    private func closeListener() {
        guard listenerFD >= 0 else { return }
        Darwin.close(listenerFD)
        listenerFD = -1
    }

    private func setNonblocking(_ fd: Int32) -> Bool {
        let existingFlags = fcntl(fd, F_GETFL)
        guard existingFlags >= 0 else { return false }
        return fcntl(fd, F_SETFL, existingFlags | O_NONBLOCK) == 0
    }

    private func requestTarget(in headers: String) -> String? {
        guard let requestLine = headers.components(separatedBy: "\r\n").first else { return nil }
        let components = requestLine.split(separator: " ")
        guard components.count >= 2, components[0] == "GET" else { return nil }
        return String(components[1])
    }

    private func header(named name: String, in headers: String) -> String? {
        for line in headers.components(separatedBy: "\r\n") {
            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name else { continue }
            return fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func headerSummary(in headers: String) -> String {
        let lines = headers.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? "missing request line"
        let names = lines.dropFirst().compactMap { line -> String? in
            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            return fields[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return "request=\(requestLine), headers=\(names.joined(separator: ","))"
    }

    private func trustedLoopbackIdentity() throws -> SecIdentity {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(query as CFDictionary, &result)
        guard lookupStatus == errSecSuccess else {
            throw ServerError.keychainIdentity(status: lookupStatus)
        }
        guard let identities = result as? [AnyObject] else {
            throw ServerError.trustedIdentityMissing
        }
        for candidate in identities where CFGetTypeID(candidate) == SecIdentityGetTypeID() {
            // Security returns opaque CFTypeRefs even after an identity-only
            // query. The checked type ID makes this bridge safe.
            let identity = unsafeDowncast(candidate, to: SecIdentity.self)
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate
            else {
                continue
            }
            let fingerprint = Data(Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data))
            if fingerprint == Self.trustedLoopbackCertificateSHA1 {
                return identity
            }
        }
        throw ServerError.trustedIdentityMissing
    }

    private static let trustedLoopbackCertificateSHA1 = Data([
        0x7C, 0x0B, 0x00, 0x95, 0x4A, 0x87, 0x64, 0x87, 0x62, 0x0B,
        0xE7, 0xB2, 0xE2, 0xD0, 0xFD, 0xEC, 0x54, 0xB8, 0xEF, 0x08,
    ])

    @MainActor
    private final class SecureConnection {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private let onHeaders: (String) -> Void
        private let onStop: () -> Void
        private var received = Data()
        private var didReceiveHeaders = false
        private var didStop = false

        init(
            connection: NWConnection,
            queue: DispatchQueue,
            onHeaders: @escaping (String) -> Void,
            onStop: @escaping () -> Void
        ) {
            self.connection = connection
            self.queue = queue
            self.onHeaders = onHeaders
            self.onStop = onStop
        }

        func start() {
            connection.start(queue: queue)
            readPendingBytes()
        }

        func send(response: Data, onSent: @escaping @MainActor @Sendable () -> Void) {
            guard !didStop else { return }
            connection.send(content: response, completion: .contentProcessed { [weak self] error in
                MainActor.assumeIsolated {
                    guard let self, !self.didStop else { return }
                    guard error == nil else {
                        self.stop()
                        return
                    }
                    onSent()
                }
            })
        }

        func stop() {
            guard !didStop else { return }
            didStop = true
            connection.cancel()
            onStop()
        }

        private func readPendingBytes() {
            guard !didStop, !didReceiveHeaders else { return }
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: Metrics.readBufferSize
            ) { [weak self] data, _, isComplete, error in
                MainActor.assumeIsolated {
                    self?.didReceive(data: data, isComplete: isComplete, error: error)
                }
            }
        }

        private func didReceive(data: Data?, isComplete: Bool, error: NWError?) {
            guard !didStop, !didReceiveHeaders else { return }
            guard error == nil else {
                stop()
                return
            }
            if let data {
                received.append(data)
                guard received.count <= Metrics.maximumHeaderBytes else {
                    stop()
                    return
                }
                if let headerRange = received.range(of: Data("\r\n\r\n".utf8)) {
                    didReceiveHeaders = true
                    let headers = String(decoding: received[..<headerRange.upperBound], as: UTF8.self)
                    onHeaders(headers)
                    return
                }
            }
            guard !isComplete else {
                stop()
                return
            }
            readPendingBytes()
        }
    }

    @MainActor
    private final class Connection {
        private let fd: Int32
        private let queue: DispatchQueue
        private let onHeaders: (String) -> Void
        private var readSource: DispatchSourceRead?
        private var writeSource: DispatchSourceWrite?
        private var pendingResponse = Data()
        private var onResponseSent: (() -> Void)?
        private var received = Data()
        private var didReceiveHeaders = false
        private var didStop = false

        init(fd: Int32, queue: DispatchQueue, onHeaders: @escaping (String) -> Void) {
            self.fd = fd
            self.queue = queue
            self.onHeaders = onHeaders
        }

        func start() {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.readPendingBytes() }
            }
            source.setCancelHandler { }
            readSource = source
            source.resume()
        }

        func send(response: Data, onSent: @escaping () -> Void) {
            guard !didStop else { return }
            pendingResponse = response
            onResponseSent = onSent
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.writePendingBytes() }
            }
            source.setCancelHandler { }
            writeSource = source
            source.resume()
            writePendingBytes()
        }

        func stop() {
            guard !didStop else { return }
            didStop = true
            readSource?.cancel()
            writeSource?.cancel()
            readSource = nil
            writeSource = nil
            Darwin.close(fd)
        }

        private func readPendingBytes() {
            guard !didStop, !didReceiveHeaders else { return }
            var buffer = [UInt8](repeating: 0, count: Metrics.readBufferSize)
            let capacity = buffer.count
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, capacity) }
                if count > 0 {
                    received.append(contentsOf: buffer.prefix(count))
                    guard received.count <= Metrics.maximumHeaderBytes else { stop(); return }
                    if let headerRange = received.range(of: Data("\r\n\r\n".utf8)) {
                        didReceiveHeaders = true
                        readSource?.cancel()
                        readSource = nil
                        let headers = String(decoding: received[..<headerRange.upperBound], as: UTF8.self)
                        onHeaders(headers)
                        return
                    }
                    continue
                }
                if count == 0 { stop(); return }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                stop()
                return
            }
        }

        private func writePendingBytes() {
            guard !didStop else { return }
            while !pendingResponse.isEmpty {
                let written = pendingResponse.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, pendingResponse.count) }
                if written > 0 {
                    pendingResponse.removeFirst(written)
                    continue
                }
                if written < 0, (errno == EAGAIN || errno == EWOULDBLOCK) { return }
                stop()
                return
            }
            writeSource?.cancel()
            writeSource = nil
            let completion = onResponseSent
            onResponseSent = nil
            completion?()
        }
    }

}
#endif
