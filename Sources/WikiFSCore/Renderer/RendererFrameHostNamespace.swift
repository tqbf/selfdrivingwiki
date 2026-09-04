import Foundation
import WikiFSTypes

/// The typed reserved namespace for host-composed frame resources.
///
/// Frame sessions need a small set of host-generated files (the frame-scoped
/// input bootstrap script) served under the frame's `renderer-package:` origin.
/// Those bytes are trusted host overlays, not package assets: they never carry
/// a manifest digest, and a validated package must not be able to shadow them.
/// Reserving the `__host__/` path prefix makes that shadowing impossible while
/// requiring no change to reviewed package manifests.
public enum RendererFrameHostNamespace {
    /// The reserved path prefix. Package manifests that declare any asset
    /// under this prefix are rejected at validation time.
    public static let reservedPrefix = "__host__/"

    /// The reserved path of the frame-scoped input bootstrap script, served
    /// by the host frame-resource layer.
    public static let inputBootstrapPath = "__host__/renderer-input.js"

    /// True when a package-relative path falls inside the reserved namespace.
    public static func isReserved(_ path: RendererRelativePath) -> Bool {
        path.rawValue.hasPrefix(reservedPrefix)
    }
}
