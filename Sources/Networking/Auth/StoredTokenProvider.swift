import Foundation

/// Default `TokenProvider` for non-expiring access tokens.
///
/// Reads, writes, and deletes the persisted `Token` through any
/// `TokenStorage`. Concurrent calls are serialized via the actor.
///
/// ```swift
/// let provider = StoredTokenProvider(
///     storage: KeychainTokenStorage(service: "com.myrepcard.RepCard")
/// )
///
/// // After sign-in:
/// try await provider.setToken(Token(accessToken: rawToken))
///
/// // Wire up the network layer:
/// let interceptor = AuthTokenInterceptor(tokenProvider: provider)
///
/// // On sign-out:
/// try await provider.clear()
/// ```
public actor StoredTokenProvider: TokenProvider {
    private let storage: any TokenStorage

    /// - Parameter storage: Where the token is persisted. Defaults to in-memory
    ///   storage; production apps should pass `KeychainTokenStorage`.
    public init(storage: any TokenStorage = InMemoryTokenStorage()) {
        self.storage = storage
    }

    public func accessToken() async throws -> String {
        guard let token = try load() else {
            throw TokenProviderError.notAuthenticated
        }
        return token.accessToken
    }

    public func setToken(_ token: Token) async throws {
        do {
            try storage.save(token)
        } catch let error as TokenProviderError {
            throw error
        } catch {
            throw TokenProviderError.storageFailed(error)
        }
    }

    public func clear() async throws {
        do {
            try storage.deleteToken()
        } catch let error as TokenProviderError {
            throw error
        } catch {
            throw TokenProviderError.storageFailed(error)
        }
    }

    public func hasToken() async -> Bool {
        (try? load()) != nil
    }

    // MARK: - Private

    private func load() throws -> Token? {
        do {
            return try storage.loadToken()
        } catch let error as TokenProviderError {
            throw error
        } catch {
            throw TokenProviderError.storageFailed(error)
        }
    }
}
