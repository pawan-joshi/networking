import Foundation

/// Where the `Token` lives between launches. Implementations must be safe to
/// call from any thread (they are exercised from inside an `actor`).
///
/// Two implementations ship with NetworkLayer:
/// - `KeychainTokenStorage` — production-ready, backed by the iOS Keychain.
/// - `InMemoryTokenStorage` — non-persistent, for tests and previews.
public protocol TokenStorage: Sendable {
    /// Load the persisted token, or `nil` when none is stored.
    func loadToken() throws -> Token?

    /// Persist `token`, replacing any previous value.
    func save(_ token: Token) throws

    /// Delete any stored token. Calling this when no token exists is a no-op.
    func deleteToken() throws
}
