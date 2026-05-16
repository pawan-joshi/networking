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
