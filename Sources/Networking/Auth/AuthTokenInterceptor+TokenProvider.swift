import Foundation

public extension AuthTokenInterceptor {
    /// Build an `AuthTokenInterceptor` that pulls its bearer token from a
    /// `TokenProvider`. This is the preferred constructor when wiring the
    /// network layer into an app.
    init(tokenProvider: any TokenProvider) {
        self.init(tokenProvider: { try await tokenProvider.accessToken() })
    }
}
