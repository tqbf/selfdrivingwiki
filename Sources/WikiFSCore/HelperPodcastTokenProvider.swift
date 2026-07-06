#if PODCAST_TRANSCRIPTS  // Apple Podcasts transcript feature; off for WIKIFS_APP_STORE=1 builds.
import Foundation

/// The production `PodcastTokenProviding`: runs the `podcast-token-helper` binary
/// (which does the private-framework FairPlay signing in an isolated process) and
/// caches the resulting JWT on disk for ~30 days, so the expensive signed call is
/// off the hot path for most fetches.
///
/// The helper is a separate executable ON PURPOSE — the reference notes the private
/// signing call can segfault during promise cleanup; a crash in the helper costs one
/// failed fetch, never the app. See `plans/podcast-transcripts.md` (step 2).
public struct HelperPodcastTokenProvider: PodcastTokenProviding {
    private let helperURL: URL
    private let cacheURL: URL
    private let maxAge: TimeInterval

    public init(
        helperURL: URL,
        cacheURL: URL = HelperPodcastTokenProvider.defaultCacheURL(),
        maxAge: TimeInterval = 60 * 60 * 24 * 30
    ) {
        self.helperURL = helperURL
        self.cacheURL = cacheURL
        self.maxAge = maxAge
    }

    /// The `podcast-token-helper` binary next to the running executable: in the app
    /// bundle it lives in `Contents/Helpers/` (sibling of `Contents/MacOS/`); in a
    /// dev/test build it sits beside the built product. Returns nil when absent, so
    /// callers can fall back gracefully.
    public static func resolveHelperURL() -> URL? {
        let name = "podcast-token-helper"
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        guard let exeDir else { return nil }
        let candidates = [
            // App bundle: Contents/MacOS/<exe> → Contents/Helpers/<helper>.
            exeDir.deletingLastPathComponent().appendingPathComponent("Helpers/\(name)"),
            // Dev/test: beside the built executable.
            exeDir.appendingPathComponent(name),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `~/Library/Application Support/SelfDrivingWiki/podcast-bearer-token.json`.
    public static func defaultCacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("SelfDrivingWiki", isDirectory: true)
            .appendingPathComponent("podcast-bearer-token.json")
    }

    public func bearerToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached = loadCachedToken() { return cached }

        let token = try await runHelper()
        // A valid JWT starts with "ey" (base64 of `{"`). Reject anything else so a
        // helper that printed an error to stdout doesn't get cached as a token.
        guard token.hasPrefix("ey"), token.count > 10 else {
            throw PodcastTranscriptError.signatureUnavailable(
                "helper returned an invalid token")
        }
        storeToken(token)
        return token
    }

    // MARK: - Helper subprocess

    private func runHelper() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = helperURL
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { proc in
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0 else {
                    let detail = String(data: err, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(proc.terminationStatus)"
                    continuation.resume(
                        throwing: PodcastTranscriptError.signatureUnavailable(
                            detail.isEmpty ? "exit \(proc.terminationStatus)" : detail))
                    return
                }
                let token = String(data: out, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: token)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(
                    throwing: PodcastTranscriptError.signatureUnavailable(
                        "couldn't launch token helper: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Disk cache

    private struct CacheEntry: Codable {
        let token: String
        let fetched: Date
    }

    private func loadCachedToken() -> String? {
        guard let data = try? Data(contentsOf: cacheURL),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data),
              Date().timeIntervalSince(entry.fetched) < maxAge,
              entry.token.hasPrefix("ey")
        else { return nil }
        return entry.token
    }

    private func storeToken(_ token: String) {
        let entry = CacheEntry(token: token, fetched: Date())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

/// The production `PodcastHTTPClient` — a thin `URLSession` wrapper. Browser-ish
/// UA so AMP serves us; no retry logic here (the service owns the refresh-retry).
public struct URLSessionPodcastHTTPClient: PodcastHTTPClient {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    public func download(_ url: URL) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
#endif
