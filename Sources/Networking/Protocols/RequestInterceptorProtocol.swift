import Foundation

// MARK: - Retry Decision

public enum RetryDecision: Sendable {
    case retry
    case retryWithDelay(TimeInterval)
    case doNotRetry
}

// MARK: - Interceptor Protocol

/// Hook into the request/response pipeline for cross-cutting concerns:
/// authentication headers, logging, request signing, retry logic, etc.
///
/// The client applies interceptors in the order they appear in the `interceptors` array.
/// Each `adapt` call can mutate the URLRequest (e.g., inject a bearer token).
/// The `retry` call is invoked after a failure and controls whether to re-execute.
public protocol RequestInterceptorProtocol: Sendable {
    /// Mutate or decorate the outgoing request before it is sent.
    func adapt(_ request: URLRequest) async throws -> URLRequest

    /// Decide whether to retry a failed request.
    /// - Parameters:
    ///   - request: The original request.
    ///   - error: The error that caused the failure.
    ///   - currentRetryCount: How many times this request has already been retried.
    func retry(
        _ request: URLRequest,
        dueTo error: NetworkError,
        currentRetryCount: Int
    ) async -> RetryDecision
}

// MARK: - Default Implementations

public extension RequestInterceptorProtocol {
    func adapt(_ request: URLRequest) async throws -> URLRequest { request }
    func retry(_ request: URLRequest, dueTo error: NetworkError, currentRetryCount: Int) async -> RetryDecision { .doNotRetry }
}

// MARK: - Built-in Interceptors

/// Injects a bearer token into requests that have `requiresAuthentication == true`.
///
/// Reads the `X-Requires-Authentication` sentinel that `NetworkRequestable.asURLRequest()`
/// encodes into every `URLRequest`, then strips it so it is never sent to the server.
/// Requests built without going through `NetworkRequestable` are treated as requiring
/// authentication (safe default).
public struct AuthTokenInterceptor: RequestInterceptorProtocol {
    private let tokenProvider: @Sendable () async throws -> String

    public init(tokenProvider: @escaping @Sendable () async throws -> String) {
        self.tokenProvider = tokenProvider
    }

    public func adapt(_ request: URLRequest) async throws -> URLRequest {
        var modified = request

        // Read and strip the sentinel — it must never reach the server.
        let sentinelValue = modified.value(forHTTPHeaderField: NetworkLayerHeader.requiresAuthentication)
        modified.setValue(nil, forHTTPHeaderField: NetworkLayerHeader.requiresAuthentication)

        // Absent sentinel → treat as requiring auth (safe default for hand-crafted requests).
        let requiresAuth = sentinelValue != "0"
        guard requiresAuth else { return modified }

        let token = try await tokenProvider()
        modified.setValue(token, forHTTPHeaderField: "userToken")
        return modified
    }
}

/// Retries up to `maxRetries` times with an optional fixed delay.
public struct RetryInterceptor: RequestInterceptorProtocol {
    private let maxRetries: Int
    private let delay: TimeInterval
    private let retryableStatusCodes: Set<Int>

    public init(
        maxRetries: Int = 3,
        delay: TimeInterval = 1.0,
        retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    ) {
        self.maxRetries = maxRetries
        self.delay = delay
        self.retryableStatusCodes = retryableStatusCodes
    }

    public func retry(
        _ request: URLRequest,
        dueTo error: NetworkError,
        currentRetryCount: Int
    ) async -> RetryDecision {
        guard currentRetryCount < maxRetries else { return .doNotRetry }

        switch error {
        case .timeout, .noInternetConnection:
            return .retryWithDelay(delay)
        case .serverError(let code, _) where retryableStatusCodes.contains(code):
            return .retryWithDelay(delay)
        default:
            return .doNotRetry
        }
    }
}
