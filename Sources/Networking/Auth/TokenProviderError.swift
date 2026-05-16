import Foundation

/// Errors surfaced by `TokenProvider` and its collaborators.
public enum TokenProviderError: Error, LocalizedError, Sendable {
    /// No token is stored — the user is not signed in.
    case notAuthenticated
    /// The underlying `TokenStorage` failed (Keychain error, decode error…).
    case storageFailed(any Error)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "No access token is available. The user must sign in."
        case .storageFailed(let error):
            "Token storage failed: \(error.localizedDescription)"
        }
    }
}
