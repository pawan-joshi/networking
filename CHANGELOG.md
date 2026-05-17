# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `AuthTokenInterceptor` — injects a bearer token into authenticated requests; strips the `X-Requires-Authentication` sentinel before the request reaches the server.
- `HeadersInterceptor` — merges a dynamic header dictionary into outgoing requests, skipping headers already set by the caller.
- `RetryInterceptor` — retries failed requests up to a configurable limit with an optional fixed delay, targeting common transient status codes (408, 429, 5xx) and network-level errors.
- `AuthTokenInterceptor` convenience initialiser accepting `any TokenProvider`, defaulting the token header field to `Authorization`.

### Changed
- Raised macOS minimum deployment target from 12 to 13 (required by `JSONDecoder` `Sendable` conformance).

### Removed
- Legacy `HTTPClientTests.swift` that imported the old `NetworkLayer` module name.

### Fixed
- Added missing `import Foundation` to `AuthTokenInterceptor`, `HeadersInterceptor`, and `RetryInterceptor` (`URLRequest` and `TimeInterval` were not in scope).
- Corrected `await try` to `try await` in `HeadersInterceptor.adapt(_:)`.
- Fixed `AuthTokenInterceptor+TokenProvider` convenience init to forward the `tokenField` argument to the designated initialiser.
- Corrected `import NetworkLayer` to `import Networking` in `MockHTTPClient` and `MockURLProtocol`.

## [1.0.0] - 2026-05-16

### Added
- Initial release.

[Unreleased]: https://github.com/pawan-joshi/networking/compare/1.0.0...HEAD
[1.0.0]: https://github.com/pawan-joshi/networking/releases/tag/1.0.0
