import Foundation

// MARK: - ResponseCache

/// A `URLCache`-backed store with a configurable default max-age.
///
/// When the server omits `Cache-Control` / `Expires` headers, `URLCache`'s built-in
/// heuristic TTL is often too aggressive. This wrapper enforces its own expiry by
/// storing an absolute `Date` in `CachedURLResponse.userInfo` (under a private key)
/// at write time, and invalidating the entry at read time when that date has passed.
/// The underlying `HTTPURLResponse` headers are never modified.
///
/// **Thread safety / `@unchecked Sendable` rationale**
///
/// `URLCache` is documented by Apple as thread-safe since iOS 8 / macOS 10.9, but it
/// does not carry a `Sendable` conformance across all deployment targets, so the
/// compiler cannot verify the conformance automatically. `@unchecked Sendable` is the
/// correct spelling here; the invariant is upheld as follows:
///
/// - `urlCache` and `defaultMaxAge` are both `let` — they are never mutated after `init`.
/// - Every `CacheStorable` method delegates directly to `URLCache`'s own thread-safe API.
/// - `cachedResponse(for:)` performs a compound read-then-remove when an entry has
///   expired. Two concurrent callers can both enter that branch simultaneously; the
///   resulting double-remove is idempotent and both callers correctly return `nil`.
public final class ResponseCache: CacheStorable, @unchecked Sendable {

    // MARK: - Properties

    private let urlCache: URLCache
    /// Fallback TTL injected into `userInfo` when the server sends no `Cache-Control` header.
    public let defaultMaxAge: TimeInterval

    // MARK: - Init

    /// - Parameters:
    ///   - memoryCapacity: In-process byte budget (default 20 MB).
    ///   - diskCapacity: On-disk byte budget (default 150 MB).
    ///   - defaultMaxAge: Fallback TTL in seconds when the server sends no cache headers (default 5 min).
    public init(
        memoryCapacity: Int = 20_000_000,
        diskCapacity: Int = 150_000_000,
        defaultMaxAge: TimeInterval = 300
    ) {
        self.urlCache = URLCache(
            memoryCapacity: memoryCapacity,
            diskCapacity: diskCapacity,
            diskPath: "com.networklayer.cache"
        )
        self.defaultMaxAge = defaultMaxAge
    }

    // MARK: - CacheStorable

    public func cachedResponse(for request: URLRequest) -> CachedURLResponse? {
        guard let cached = urlCache.cachedResponse(for: request) else { return nil }

        // Validate against our custom `X-Cache-Expiry` header if present.
        if let expiresAt = cached.userInfo?[CacheKey.expiresAt] as? Date,
           Date() > expiresAt {
            urlCache.removeCachedResponse(for: request)
            return nil
        }
        return cached
    }

    public func storeCachedResponse(_ cachedResponse: CachedURLResponse, for request: URLRequest) {
        // If no Cache-Control is set by the server, inject our default max-age into userInfo.
        let httpResponse = cachedResponse.response as? HTTPURLResponse
        let hasServerCacheDirective = httpResponse?
            .value(forHTTPHeaderField: "Cache-Control") != nil

        if !hasServerCacheDirective {
            var userInfo = cachedResponse.userInfo ?? [:]
            userInfo[CacheKey.expiresAt] = Date().addingTimeInterval(defaultMaxAge)
            let patched = CachedURLResponse(
                response: cachedResponse.response,
                data: cachedResponse.data,
                userInfo: userInfo,
                storagePolicy: cachedResponse.storagePolicy
            )
            urlCache.storeCachedResponse(patched, for: request)
        } else {
            urlCache.storeCachedResponse(cachedResponse, for: request)
        }
    }

    public func removeCachedResponse(for request: URLRequest) {
        urlCache.removeCachedResponse(for: request)
    }

    public func removeAllCachedResponses() {
        urlCache.removeAllCachedResponses()
    }

    // MARK: - Convenience

    public var currentMemoryUsage: Int { urlCache.currentMemoryUsage }
    public var currentDiskUsage: Int { urlCache.currentDiskUsage }

    private enum CacheKey {
        static let expiresAt = "com.networklayer.cache.expiresAt"
    }
}

// MARK: - NullCache (disables caching entirely — useful in tests or for sensitive endpoints)

public final class NullCache: CacheStorable, Sendable {
    public init() {}
    public func cachedResponse(for request: URLRequest) -> CachedURLResponse? { nil }
    public func storeCachedResponse(_ cachedResponse: CachedURLResponse, for request: URLRequest) {}
    public func removeCachedResponse(for request: URLRequest) {}
    public func removeAllCachedResponses() {}
}
