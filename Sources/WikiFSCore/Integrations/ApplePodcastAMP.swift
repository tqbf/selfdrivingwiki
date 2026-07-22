#if PODCAST_TRANSCRIPTS  // Apple Podcasts transcript feature; off for WIKIFS_APP_STORE=1 builds.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The AMP transcript-metadata request: episode ID + bearer token → the direct,
/// access-key'd TTML URL. The HTTP round-trip is behind an injected
/// `PodcastHTTPClient` so the request-building, status handling, and JSON decoding
/// are unit-tested against the REAL captured response shape without any network.
///
/// See `plans/podcast-transcripts.md` (step 3).
public enum ApplePodcastAMP {

    /// The AMP `/transcripts` response we care about:
    /// `data[0].attributes.ttmlAssetUrls.ttml`.
    struct TranscriptResponse: Decodable {
        struct Datum: Decodable { let attributes: Attributes }
        struct Attributes: Decodable { let ttmlAssetUrls: TTMLAssetUrls? }
        struct TTMLAssetUrls: Decodable { let ttml: String? }
        let data: [Datum]
    }

    /// Build the AMP transcripts request for an episode, carrying the bearer token.
    /// Matches the reference: `fields`, `include[podcast-episodes]`, `l`, `with`.
    public static func request(episodeID: String, token: String) -> URLRequest {
        var comps = URLComponents(string:
            "https://amp-api.podcasts.apple.com/v1/catalog/us/podcast-episodes/\(episodeID)/transcripts")!
        comps.queryItems = [
            .init(name: "fields", value: "ttmlToken,ttmlAssetUrls"),
            .init(name: "include[podcast-episodes]", value: "podcast"),
            .init(name: "l", value: "en-US"),
            .init(name: "with", value: "entitlements"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("https://podcasts.apple.com", forHTTPHeaderField: "Origin")
        return req
    }

    /// Decide the outcome of an AMP response: the TTML URL, or a typed error.
    /// PURE (bytes + status in, result out) so the 40012 / no-transcript / bad-status
    /// branches are all unit-tested. A 400 body containing `40012` → the
    /// permissions error the caller retries once after a forced token refresh.
    public static func ttmlURL(fromStatus status: Int, body: Data) throws -> URL {
        if status == 400, let text = String(data: body, encoding: .utf8), text.contains("40012") {
            throw PodcastTranscriptError.insufficientPermissions
        }
        guard status == 200 else { throw PodcastTranscriptError.badResponse(status) }

        guard let decoded = try? JSONDecoder().decode(TranscriptResponse.self, from: body),
              let ttml = decoded.data.first?.attributes.ttmlAssetUrls?.ttml,
              let url = URL(string: ttml)
        else { throw PodcastTranscriptError.noTranscriptAvailable }
        return url
    }
}
#endif
