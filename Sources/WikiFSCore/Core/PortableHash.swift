// Compatibility adapter for existing Core callers. The portable typed SHA-256
// primitive lives in WikiFSTypes/Renderer/RendererSHA256.swift.

import Foundation
import WikiFSTypes

func portableSHA256(_ data: Data) -> [UInt8] {
    RendererSHA256.digest(data).bytes
}
