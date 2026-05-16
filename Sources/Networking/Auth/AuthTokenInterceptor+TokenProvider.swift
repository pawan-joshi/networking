import Foundation

public extension AuthTokenInterceptor {
    /// Build an `AuthTokenInterceptor` that pulls its bearer token from a
    /// `TokenProvider`. This is the preferred constructor when wiring the
    /// network layer into an app.
    init(tokenField: String = "Authorization", tokenProvider: any TokenProvider) {
        self.init(tokenField: tokenField, tokenProvider: { try await tokenProvider.accessToken() })
    }
}
