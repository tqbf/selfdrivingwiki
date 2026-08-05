import Foundation

// pattern: Functional Core

/// Pure name routing for payload-free renderer wakes. Resource notification
/// names are intentionally not accepted here, so callers cannot accidentally
/// turn renderer settings into a `ResourceChangeEvent`.
public enum RendererMachineWakeRouting {
    public static func scope(forNotificationName name: String, observedScopes: Set<RendererMachineScopeID>) -> RendererMachineScopeID? {
        observedScopes.first { name == RendererChangeNotification.machineName(for: $0) }
    }
}
