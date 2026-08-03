# Dynamic renderer PR 1 model

## Scope

PR 1 adds only portable renderer contracts in `WikiFSTypes`. It does not read
package directories, install packages, persist preferences, create UI, or run
WebKit.

## Identifier boundaries

`RendererPackageID`, `RendererPackageVersion`, and `RendererRegistrationID`
are separate `RawRepresentable` types. A `RendererReference` contains all
three. A `LogicalRendererReference` contains only the package and registration
identities. The compiler rejects a version where an exact package ID is needed.

Package IDs use lowercase reverse-DNS labels. Registration IDs use lowercase
slugs. Package versions use a canonical three-part semantic version.

## Matching and selection

The host provides normalized MIME, extension, bounded sniff bytes, and artifact
kind. `RendererMatchingLimits.maximumSniffByteCount` is 4,096 bytes. A matcher
cannot inspect bytes outside that bound.

MIME, signature, and artifact-kind matches are strong matches. Extension
matches run only when no strong match exists. The resolver sorts equal-tier
descriptors by descending priority, then ascending package ID, package version,
and registration ID. Input and installation order cannot affect this result.

An available compatible exact preference wins. If it is unavailable, a logical
preference selects the highest compatible semantic version. It then uses the
same stable tie-break key.

## Hash contract

`RendererSHA256Digest` contains exactly 32 bytes. Its text format is exactly 64
lowercase hexadecimal characters. `RendererSHA256` uses CryptoKit on macOS and
swift-crypto on Linux. Existing Core hashing delegates to this primitive.

The package hash is SHA-256 over a canonical JSON envelope. The envelope has a
format label, revision, normalized manifest, and sorted asset paths with their
canonical digest text. Manifest revision 1 is the only supported revision.

## Test and audit records

`plans/dynamic-renderers-pr1-test-inventory.json` maps PR 1 contract symbols
and decision branches to named tests. The Phase 0 gate schema and PR series
relationship file support exact-head evidence under gitignored `tmp/`.
