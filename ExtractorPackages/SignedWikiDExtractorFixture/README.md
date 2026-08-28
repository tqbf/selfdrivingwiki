# Signed wikid Extractor Fixture

This reviewed fixture proves the production process boundary. The signed app and its `wikid.xpc` service contain identical package resources.

The build puts the no-dependency `ExtractorProcessFixture` binary at `bin/extractor-process-fixture`. The fixture accepts one JSON request and emits bounded JSON Lines frames.

This package is test-only. It is not an extraction backend and users cannot select it.
