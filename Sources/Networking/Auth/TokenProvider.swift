import Foundation

/// Vends bearer access tokens to the network layer.
///
/// Implementations are responsible for returning a valid access token and
/// persisting tokens across launches (typically through `TokenStorage`).
///
/// Plug an implementation into `AuthTokenInterceptor` via the convenience
/// initializer in `AuthTokenInterceptor+TokenProvider.swift`.
public protocol TokenProvider: Sendable {
    /// Returns the stored access token. Throws
    /// `TokenProviderError.notAuthenticated` when no token is stored.
    func accessToken() async throws -> String

    /// Persist a freshly issued token (e.g. after a sign-in).
    func setToken(_ token: Token) async throws

    /// Drop any stored token (e.g. on sign-out).
    func clear() async throws

    /// `true` when a token is currently stored.
    func hasToken() async -> Bool
}
