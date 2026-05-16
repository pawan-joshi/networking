import Foundation

// MARK: - Protocol

/// Describes a single HTTP request. Conform to this to define API endpoints.
/// Provides sensible defaults via a protocol extension so conforming types only
/// need to specify what differs from the standard.
public protocol NetworkRequestable: Sendable {
    var baseURL: URL { get }
    var path: String { get }
    var method: HTTPMethod { get }
    var headers: [String: String]? { get }
    var queryParameters: [String: String]? { get }
    var body: (any Encodable & Sendable)? { get }
    var timeoutInterval: TimeInterval { get }
    var cachePolicy: URLRequest.CachePolicy { get }
    var requiresAuthentication: Bool { get }

    func asURLRequest() throws -> URLRequest
}

// MARK: - Default Implementation

public extension NetworkRequestable {
    var headers: [String: String]? { nil }
    var queryParameters: [String: String]? { nil }
    var body: (any Encodable & Sendable)? { nil }
    var timeoutInterval: TimeInterval { 30 }
    var cachePolicy: URLRequest.CachePolicy { .useProtocolCachePolicy }
    var requiresAuthentication: Bool { true }

    func asURLRequest() throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: true
        ) else {
            throw NetworkError.invalidURL
        }

        if let queryParameters, !queryParameters.isEmpty {
            components.queryItems = queryParameters
                .sorted(by: { $0.key < $1.key })
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components.url else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: timeoutInterval)
        request.httpMethod = method.rawValue

        // Sentinel read by AuthTokenInterceptor; stripped before the request leaves the device.
        request.setValue(
            requiresAuthentication ? "1" : "0",
            forHTTPHeaderField: NetworkLayerHeader.requiresAuthentication
        )

        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        if let body {
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.httpBody = try body.toData()
        }

        return request
    }
}

// MARK: - Internal Header Names

/// Module-internal sentinel headers that travel inside `URLRequest` so interceptors
/// can read state derived from `NetworkRequestable`. Always stripped before sending.
enum NetworkLayerHeader {
    /// Carries the `requiresAuthentication` flag from `NetworkRequestable` to `AuthTokenInterceptor`.
    static let requiresAuthentication = "X-Requires-Authentication"
}

// MARK: - Encodable Helper

private extension Encodable {
    /// Encodes `self` to JSON data. Called on the opened existential so the
    /// generic encoder receives a concrete type — no type-erasure wrapper needed.
    func toData(encoder: JSONEncoder = .init()) throws -> Data {
        try encoder.encode(self)
    }
}
