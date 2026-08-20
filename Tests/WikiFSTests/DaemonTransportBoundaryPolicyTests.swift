#if os(macOS)
import Foundation
import Testing
@testable import WikiDaemonContract

@Suite("Daemon transport boundary policy")
struct DaemonTransportBoundaryPolicyTests {
    @Test("engine transport public surface is headless")
    func engineTransportPublicSurfaceIsHeadless() throws {
        let root = repositoryRoot()
        let paths = [
            "Sources/WikiFSEngine/DaemonTransportRuntime.swift",
            "Sources/WikiFSEngine/DaemonTransportCompositionOwner.swift",
            "Sources/WikiFSEngine/DaemonTransportRuntimeAssembly.swift",
        ]
        let forbidden = [
            "WikiDaemonConnection", "NSXPCConnection", "WikiDaemonProtocol",
            "WikiDaemonEventSink", "DaemonWorkloadClient", "XPCQueueEngineProxy",
            "QueueStore", "WikiStore", "WikiStoreModel", "WikiSession", "SessionManager",
            "SwiftUI", "AppKit",
        ]
        for path in paths {
            let source = try read(path, root: root)
            for symbol in forbidden {
                #expect(!source.contains(symbol), "Forbidden \(symbol) in \(path)")
            }
        }
    }

    @Test("app bridge coordinator and presentation adapter expose no Cordis API")
    func appAdaptersExposeNoCordisAPI() throws {
        let root = repositoryRoot()
        let bridgePath = "Sources/WikiFS/Queue/DaemonTransportAppBridge.swift"
        let coordinatorPath = "Sources/WikiFS/Queue/DaemonTransportAppCoordinator.swift"
        let presentationPath = "Sources/WikiFS/Queue/DaemonHealthMonitor.swift"
        let sources = [bridgePath, coordinatorPath, presentationPath]
        for path in sources {
            let source = try read(path, root: root)
            for symbol in ["import Cordis", "CordisContext", "ActivationContext", "ServiceKey<"] {
                #expect(!source.contains(symbol), "Forbidden \(symbol) in \(path)")
            }
        }

        let bridge = try read(bridgePath, root: root)
        let coordinator = try read(coordinatorPath, root: root)
        let presentation = try read(presentationPath, root: root)
        #expect(bridge.contains("DaemonTransportConnectionFactory"))
        #expect(bridge.contains("DaemonTransportConnection"))
        #expect(!coordinator.contains("DaemonTransportConnectionFactory"))
        #expect(!coordinator.contains("DaemonTransportConnection"))
        #expect(!presentation.contains("DaemonTransportConnectionFactory"))
        #expect(!presentation.contains("DaemonTransportConnection"))
        for source in [bridge, coordinator, presentation] {
            #expect(source.contains("DaemonTransportCandidateID") || source == presentation)
        }
        #expect(coordinator.contains("DaemonTransportServices"))
        #expect(coordinator.contains("DaemonTransportEvent"))
        #expect(presentation.contains("DaemonTransportServices"))
        #expect(presentation.contains("DaemonTransportEvent"))
    }

    @Test("explicit app and daemon consumers contain no Cordis construction API")
    func explicitConsumersContainNoCordisConstructionAPI() throws {
        let root = repositoryRoot()
        let paths = [
            "Sources/WikiFS/Queue/DaemonHealthMonitor.swift",
            "Sources/WikiFS/Queue/DaemonTransportAppCoordinator.swift",
            "Sources/WikiFS/Queue/DaemonTransportAppBridge.swift",
            "Sources/WikiFS/Queue/LocalQueueRuntimeController.swift",
            "Sources/WikiFS/Queue/QueueEngineHotSwap.swift",
            "Sources/WikiFS/Window/WikiFSApp.swift",
            "Sources/WikiFS/Chats/ChatDaemonCoordinator.swift",
        ]
        for path in paths {
            let source = try read(path, root: root)
            for symbol in ["import Cordis", "CordisContext", "ActivationContext", "ServiceKey<"] {
                #expect(!source.contains(symbol), "Forbidden \(symbol) in \(path)")
            }
        }
    }

    @Test("chat nil state is a reconnecting state, not a manual install failure")
    func chatUnavailableCopyDoesNotRequireManualDaemonInstall() throws {
        let source = try read(
            "Sources/WikiFS/Window/WikiDetailView.swift",
            root: repositoryRoot())

        #expect(!source.contains("make install-daemon"))
        #expect(source.contains("Chat will connect automatically"))
        #expect(!WikiDaemonError.connectionFailed.localizedDescription.contains("make install-daemon"))
    }

    @Test("safe queue relinquishment keeps chat connected")
    func safeQueueRelinquishmentKeepsChatConnected() throws {
        let source = try read(
            "Sources/WikiFS/Queue/DaemonTransportAppCoordinator.swift",
            root: repositoryRoot())

        #expect(!source.contains("return .localFallbackReady"))
        #expect(source.contains("replaceChatCoordinator(makeChatCoordinator())"))
    }
}

private func read(_ path: String, root: URL) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
#endif
