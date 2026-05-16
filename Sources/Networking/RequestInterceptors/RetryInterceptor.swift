import Foundation

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
