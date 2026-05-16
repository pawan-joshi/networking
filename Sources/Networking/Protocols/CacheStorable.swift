import Foundation

/// Abstracts the caching layer so it can be replaced with an in-memory stub in tests.
public protocol CacheStorable: Sendable {
    func cachedResponse(for request: URLRequest) -> CachedURLResponse?
    func storeCachedResponse(_ cachedResponse: CachedURLResponse, for request: URLRequest)
    func removeCachedResponse(for request: URLRequest)
    func removeAllCachedResponses()
}

// MARK: - URLCache Conformance

extension URLCache: CacheStorable {}
