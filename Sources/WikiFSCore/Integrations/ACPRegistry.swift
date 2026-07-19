import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The official ACP agent registry JSON (issue #665):
/// https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json
///
/// The registry is the canonical provider catalog — a fetch returns 38 official
/// ACP agents, each with a `distribution` (npx / binary / uvx) telling us how to
/// spawn it. This file mirrors the schema as `Codable` types and provides a
/// best-effort client (`ACPRegistryClient`) that:
///
/// 1. serves a fresh cache (24h TTL) when available,
/// 2. else fetches the live registry from the CDN (10s timeout, never throws),
/// 3. else serves a stale cache,
/// 4. else falls back to the bundled snapshot (`acp-registry.json` in the app's
///    `Contents/Resources`),
/// 5. else falls back to `ACPProviderCatalog.fallbackCatalog` (the hardcoded
///    list that predates #665).
///
/// Never blocks the UI, never crashes on network failure — `loadAgents()` is
/// always best-effort and returns SOME list (possibly the hardcoded fallback).
///
/// `ACPProviderCatalog.loadAgents()` is the public entry point; the `agents`
/// sync computed property is a quick bundled-snapshot-or-fallback read for
/// contexts that can't `await` (SwiftUI previews, test fixtures).

// MARK: - Schema

/// The top-level registry response.
struct ACPRegistryResponse: Codable, Sendable {
    let version: String
    let agents: [ACPRegistryAgent]
    /// Optional / future; empty array in v1.0.0. Ignored on decode.
    let extensions: [ACPRegistryExtension]?
}

/// A single agent entry.
struct ACPRegistryAgent: Codable, Sendable {
    let id: String
    let name: String
    let description: String?
    let version: String?
    let distribution: ACPRegistryDistribution?
    let icon: String?
    let repository: String?
    let website: String?
    let license: String?
    let authors: [String]?
}

/// Reserved for future use (the registry's `extensions` array is empty in
/// v1.0.0). Decoded as a permissive key→value map so future additions don't
/// break the parse.
struct ACPRegistryExtension: Codable, Sendable {
    let id: String?
    let name: String?
}

/// Discriminated by an outer key: `npx`, `binary`, or `uvx`. The official
/// schema also lets an agent carry at most one (enforced here by decoding the
/// first matching key — preserves forward-compat if the registry ever adds a
/// second distribution per agent).
enum ACPRegistryDistribution: Codable, Sendable, Equatable {
    case npx(ACPRegistryNpx)
    /// Keyed by platform triple, e.g. `"darwin-aarch64"`, `"linux-x86_64"`.
    case binary([String: ACPRegistryBinary])
    case uvx(ACPRegistryUvx)
}

struct ACPRegistryNpx: Codable, Sendable, Equatable {
    let package: String
    let args: [String]?
    let env: [String: String]?
}

struct ACPRegistryBinary: Codable, Sendable, Equatable {
    let archive: String?
    let cmd: String
    let args: [String]?
}

struct ACPRegistryUvx: Codable, Sendable, Equatable {
    let package: String
    let args: [String]?
}

// MARK: - Distribution: custom Codable (inspect the JSON keys)

extension ACPRegistryDistribution {
    private enum CodingKey: String, Swift.CodingKey {
        case npx, binary, uvx
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKey.self)
        // Prefer npx, then binary, then uvx — a single-distribution entry is
        // the norm; this is forward-compatible if the registry ever carries
        // more than one per agent (we take the first we recognize).
        if let npx = try c.decodeIfPresent(ACPRegistryNpx.self, forKey: .npx) {
            self = .npx(npx)
        } else if let binary = try c.decodeIfPresent([String: ACPRegistryBinary].self, forKey: .binary) {
            self = .binary(binary)
        } else if let uvx = try c.decodeIfPresent(ACPRegistryUvx.self, forKey: .uvx) {
            self = .uvx(uvx)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKey.npx,
                in: c,
                debugDescription: "ACPRegistryDistribution: no npx/binary/uvx key"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKey.self)
        switch self {
        case .npx(let v): try c.encode(v, forKey: .npx)
        case .binary(let v): try c.encode(v, forKey: .binary)
        case .uvx(let v): try c.encode(v, forKey: .uvx)
        }
    }
}

// MARK: - Registry client

/// Fetches the official ACP registry with caching + offline fallback (#665).
///
/// Never throws — every error is logged via `DebugLog.agent` and the call
/// degrades to the next layer (stale cache → bundled snapshot → hardcoded
/// `ACPProviderCatalog.fallbackCatalog`). The single public entry point is
/// `loadAgents()` (async); `ACPProviderCatalog.agents` calls `mapRegistryToCatalog`
/// on the bundled snapshot for its sync path.
struct ACPRegistryClient: Sendable {
    /// CDN URL for the official agent registry (issue #665).
    static let registryURL = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!

    /// Cache location: Application Support/Self Driving Wiki/acp-registry.json.
    /// Lives outside the bundle so a fetch survives across launches (next launch
    /// serves the cache fresh-or-stale before re-fetching).
    static let cacheURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Self Driving Wiki/acp-registry.json")

    /// Bundled snapshot (offline fallback when no cache + no network).
    /// Resolved the same way the bundled `mermaid.js` / `merval.js` are.
    static let bundledURL = Bundle.main.url(forResource: "acp-registry", withExtension: "json")

    /// Cache TTL: 24 hours. A fresh fetch is performed only when the cache is
    /// older than this (or absent). Stale cache is still served if the fetch
    /// fails — never block on the network.
    static let cacheTTL: TimeInterval = 86_400

    /// Network timeout for the fetch (per-request). Conservative so an offline
    /// machine fails fast and falls through to the bundled fallback without
    /// holding the UI's `.task` open for the full default 60s.
    static let fetchTimeout: TimeInterval = 10

    /// Load the registry: try cache (if fresh), then fetch, then stale cache,
    /// then bundled snapshot, then hardcoded fallback. Returns a `[KnownACPAgent]`
    /// mapped from whichever source succeeded; never empty (the hardcoded
    /// fallback always returns the 12 pre-#665 entries).
    static func loadAgents() async -> [KnownACPAgent] {
        // 1. Fresh cache → serve immediately, no network.
        if let cached = loadFromCache(), !isStale(cacheURL) {
            return mapRegistryToCatalog(cached)
        }

        // 2. Live fetch — non-blocking on errors (returns nil → fall through).
        if let fetched = await fetchRegistry() {
            saveToCache(fetched)
            return mapRegistryToCatalog(fetched)
        }

        // 3. Stale cache is better than the bundled snapshot (it was right at
        //    some point, even if now past TTL — e.g. the user is offline but
        //    had a successful fetch last week).
        if let stale = loadFromCache() {
            return mapRegistryToCatalog(stale)
        }

        // 4. Bundled snapshot — the official registry at the time we shipped.
        if let bundled = loadFromBundled() {
            return mapRegistryToCatalog(bundled)
        }

        // 5. Last resort: pre-#665 hardcoded catalog (always non-empty).
        return ACPProviderCatalog.fallbackCatalog
    }

    // MARK: - Fetch

    /// Fetch the live registry from the CDN. Never throws — errors land in
    /// `DebugLog.agent` and the function returns `nil` so the caller falls
    /// through to the next layer.
    private static func fetchRegistry() async -> ACPRegistryResponse? {
        var request = URLRequest(url: registryURL)
        request.timeoutInterval = fetchTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Use the same ephemeral URLSession as `URLSessionFetcher` — no cookies,
        // no caching, no shared state.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = fetchTimeout
        config.timeoutIntervalForResource = fetchTimeout * 2
        let session = URLSession(configuration: config)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            DebugLog.agent("ACPRegistryClient.fetch: network error — \(error.localizedDescription)")
            return nil
        }

        // Non-HTTP (file://, etc.) — accept as JSON and try to decode.
        if !(response is HTTPURLResponse) {
            return decodeRegistry(data, source: "non-HTTP")
        }

        guard let http = response as? HTTPURLResponse else {
            DebugLog.agent("ACPRegistryClient.fetch: non-HTTP response — discarding")
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            DebugLog.agent("ACPRegistryClient.fetch: HTTP \(http.statusCode) — discarding")
            return nil
        }
        return decodeRegistry(data, source: "HTTP \(http.statusCode)")
    }

    /// Decode the JSON payload, logging a structured error on failure. Never
    /// throws.
    private static func decodeRegistry(_ data: Data, source: String) -> ACPRegistryResponse? {
        do {
            return try JSONDecoder().decode(ACPRegistryResponse.self, from: data)
        } catch {
            DebugLog.agent("ACPRegistryClient.fetch: decode failed (\(source)) — \(error)")
            return nil
        }
    }

    // MARK: - Cache I/O

    /// Read the cache file from Application Support. Returns nil on any I/O or
    /// decode failure (logged, then degraded). Never throws.
    private static func loadFromCache() -> ACPRegistryResponse? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: cacheURL)
            return try JSONDecoder().decode(ACPRegistryResponse.self, from: data)
        } catch {
            // A corrupt cache is fine — we'll re-fetch over it.
            DebugLog.agent("ACPRegistryClient.loadFromCache: failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// Write the freshly-fetched registry to the cache file. Creates the
    /// parent directory if absent. Never throws — a write failure leaves the
    /// old cache (or the bundled fallback) in place.
    private static func saveToCache(_ response: ACPRegistryResponse) {
        let dir = cacheURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        } catch {
            DebugLog.agent("ACPRegistryClient.saveToCache: mkdir failed — \(error.localizedDescription)")
            return
        }
        do {
            let data = try JSONEncoder().encode(response)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            DebugLog.agent("ACPRegistryClient.saveToCache: write failed — \(error.localizedDescription)")
        }
    }

    /// Read the bundled snapshot from `Contents/Resources/acp-registry.json`
    /// (shipped by `build.sh`). Never throws.
    private static func loadFromBundled() -> ACPRegistryResponse? {
        guard let url = bundledURL else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ACPRegistryResponse.self, from: data)
        } catch {
            DebugLog.agent("ACPRegistryClient.loadFromBundled: failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// True when the cache file's modification date is older than `cacheTTL`.
    /// Calling this with no cache file present returns `true` (so the caller
    /// always tries to fetch when the cache is absent — that's the right call
    /// anyway: there's nothing useful to serve from disk).
    private static func isStale(_ url: URL) -> Bool {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let mod = attrs[.modificationDate] as? Date ?? .distantPast
            return Date().timeIntervalSince(mod) > cacheTTL
        } catch {
            // Stat failed — treat as stale so the caller re-fetches.
            return true
        }
    }

    // MARK: - Mapping

    /// Map a registry response to the `[KnownACPAgent]` the rest of the app
    /// consumes. Public (rather than private) so `ACPProviderCatalog.agents`'
    /// sync bundled-snapshot path can call it. Pure — no I/O.
    static func mapRegistryToCatalog(_ response: ACPRegistryResponse) -> [KnownACPAgent] {
        response.agents.compactMap { agent in
            guard let dist = agent.distribution,
                  let spawn = ACPRegistryClient.spawn(for: dist) else {
                // Distribution nil or unsupported for this platform → skip.
                return nil
            }
            return KnownACPAgent(
                id: agent.id,
                label: agent.name,
                summary: agent.description ?? "",
                detectExecutable: spawn.detect,
                command: spawn.command
            )
        }
    }

    /// Translate a distribution into the spawn argv + the PATH-detect binary.
    /// Returns nil when the distribution is unsupported on this platform (e.g.
    /// a binary distribution with no `darwin-aarch64` / `darwin-x86_64`
    /// entry — the agent can't be run here).
    ///
    /// Per #665:
    /// - `npx` → `command = ["npx", package] + args`, `detectExecutable = "npx"`.
    /// - `binary (darwin-aarch64)` → `command = [cmd] + args`,
    ///   `detectExecutable` = `cmd` with a leading `"./"` stripped. Falls back
    ///   to `darwin-x86_64` if the aarch64 entry is absent (the binary will
    ///   run under Rosetta on an Apple-Silicon Mac).
    /// - `uvx` → `command = ["uvx", package] + args`, `detectExecutable = "uvx"`.
    private static func spawn(
        for distribution: ACPRegistryDistribution
    ) -> (detect: String, command: [String])? {
        switch distribution {
        case .npx(let npx):
            var command = ["npx", npx.package]
            if let args = npx.args { command.append(contentsOf: args) }
            return ("npx", command)
        case .uvx(let uvx):
            var command = ["uvx", uvx.package]
            if let args = uvx.args { command.append(contentsOf: args) }
            return ("uvx", command)
        case .binary(let platforms):
            // Prefer the native arch; fall back to x86_64 (Rosetta).
            let platform = platforms["darwin-aarch64"] ?? platforms["darwin-x86_64"]
            guard let bin = platform else { return nil }
            let detect = bin.cmd.hasPrefix("./") ? String(bin.cmd.dropFirst(2)) : bin.cmd
            var command = [detect]
            if let args = bin.args { command.append(contentsOf: args) }
            return (detect, command)
        }
    }
}
