import Foundation

/// `TokenStorage` that keeps the token in memory only.
///
/// Intended for unit tests, SwiftUI previews, and short-lived flows where
/// persistence isn't desired. The implementation is thread-safe.
public final class InMemoryTokenStorage: TokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var token: Token?

    public init(initialToken: Token? = nil) {
        self.token = initialToken
    }

    public func loadToken() throws -> Token? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    public func save(_ token: Token) throws {
        lock.lock(); defer { lock.unlock() }
        self.token = token
    }

    public func deleteToken() throws {
        lock.lock(); defer { lock.unlock() }
        token = nil
    }
}
