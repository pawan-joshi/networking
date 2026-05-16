import Foundation

public enum NetworkError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case noData
    case decodingFailed(any Error)
    case encodingFailed(any Error)
    /// A non-2xx HTTP status code was returned. `data` carries the raw error body when present.
    case serverError(statusCode: Int, data: Data?)
    case unauthorized                      // 401
    case forbidden                         // 403
    case notFound                          // 404
    case timeout
    case noInternetConnection
    case cancelled
    case cacheError(any Error)
    case unknown(any Error)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .invalidURL:                  return "The URL is malformed or empty."
        case .invalidResponse:             return "The server returned an unrecognisable response."
        case .noData:                      return "The server returned an empty body."
        case .decodingFailed(let e):       return "Response decoding failed: \(e.localizedDescription)"
        case .encodingFailed(let e):       return "Request encoding failed: \(e.localizedDescription)"
        case .serverError(let code, _):    return "Server error (HTTP \(code))."
        case .unauthorized:                return "Authentication required (HTTP 401)."
        case .forbidden:                   return "Access denied (HTTP 403)."
        case .notFound:                    return "Resource not found (HTTP 404)."
        case .timeout:                     return "The request timed out."
        case .noInternetConnection:        return "No internet connection."
        case .cancelled:                   return "The request was cancelled."
        case .cacheError(let e):           return "Cache error: \(e.localizedDescription)"
        case .unknown(let e):              return "An unexpected error occurred: \(e.localizedDescription)"
        }
    }

    // MARK: - Equatable (structural — ignores embedded errors)

    public static func == (lhs: NetworkError, rhs: NetworkError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidURL, .invalidURL),
             (.invalidResponse, .invalidResponse),
             (.noData, .noData),
             (.unauthorized, .unauthorized),
             (.forbidden, .forbidden),
             (.notFound, .notFound),
             (.timeout, .timeout),
             (.noInternetConnection, .noInternetConnection),
             (.cancelled, .cancelled):
            return true
        case (.serverError(let lc, _), .serverError(let rc, _)):
            return lc == rc
        default:
            return false
        }
    }

    // MARK: - URLError Mapping

    /// Converts any `Error` (typically a `URLError`) into a typed `NetworkError`.
    static func map(_ error: Error) -> NetworkError {
        if let networkError = error as? NetworkError { return networkError }
        guard let urlError = error as? URLError else {
            return .unknown(error)
        }
        switch urlError.code {
        case .timedOut:
            return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .noInternetConnection
        case .cancelled:
            return .cancelled
        default:
            return .unknown(urlError)
        }
    }
}
