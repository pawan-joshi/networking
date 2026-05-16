import Foundation

/// Injects a bearer token into requests that have `requiresAuthentication == true`.
///
/// Reads the `X-Requires-Authentication` sentinel that `NetworkRequestable.asURLRequest()`
/// encodes into every `URLRequest`, then strips it so it is never sent to the server.
/// Requests built without going through `NetworkRequestable` are treated as requiring
/// authentication (safe default).
public struct AuthTokenInterceptor: RequestInterceptorProtocol {
    private let tokenProvider: @Sendable () async throws -> String
    private let tokenField: String

    public init(tokenField: String, tokenProvider: @escaping @Sendable () async throws -> String) {
        self.tokenProvider = tokenProvider
        self.tokenField = tokenField
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
        modified.setValue(token, forHTTPHeaderField: tokenField)
        return modified
    }
}
