// pattern: Imperative Shell

import Foundation
import WikiFSCore

/// Owns the daemon-only checkout location for one tracked repository.
enum DaemonRepoCheckout {
    static func directory(wikiID: WikiID, repositoryID: TrackedRepoID) throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let wikiDirectory = applicationSupport
            .appendingPathComponent("WikiFS", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(wikiID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(
            at: wikiDirectory,
            withIntermediateDirectories: true)
        return wikiDirectory
            .appendingPathComponent(repositoryID.rawValue, isDirectory: true)
            .standardizedFileURL
    }

    static func exists(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.path)
    }
}
