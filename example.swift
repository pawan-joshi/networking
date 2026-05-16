// example.swift
//
// Reference usage for the NetworkLayer package. This file sits at the package
// root and is intentionally outside the `Sources/` tree so SPM does not compile
// it as part of the library. Copy what you need into your app target.

import Foundation
import Networking

// MARK: - 1. Models

/// Request body sent to POST /auth/login.
struct LoginRequest: Encodable, Sendable {
    let email: String
    let password: String
}

/// What the server returns on a successful login.
struct LoginResponse: Decodable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int   // seconds
    let user: AuthenticatedUser
}

struct AuthenticatedUser: Decodable, Equatable {
    let id: Int
    let email: String
    let name: String
}

// MARK: - 2. Endpoint

/// A single namespace describing every endpoint your auth feature talks to.
/// Conform once, and every case automatically participates in caching,
/// interceptors, retries, and progress reporting.
enum AuthEndpoint: NetworkRequestable {
    case login(email: String, password: String)
    case currentUser

    var baseURL: URL { URL(string: "https://api.repcard.com")! }

    var path: String {
        switch self {
        case .login:        return "/v1/auth/login"
        case .currentUser:  return "/v1/users/me"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .login:        return .post
        case .currentUser:  return .get
        }
    }

    var body: (any Encodable & Sendable)? {
        switch self {
        case let .login(email, password):
            return LoginRequest(email: email, password: password)
        case .currentUser:
            return nil
        }
    }

    /// Login itself is unauthenticated — the user has no token yet.
    /// Every other endpoint defaults to `true` via the protocol extension.
    var requiresAuthentication: Bool {
        switch self {
        case .login:        return false
        case .currentUser:  return true
        }
    }
}

// MARK: - 3. Response Envelope

/// Standard envelope every endpoint on this API returns.
///
/// ```json
/// {
///   "statusCode": "success",
///   "status":     "success",
///   "result":     { ... },
///   "message":    "..."
/// }
/// ```
///
/// `T` is the actual payload type. For endpoints with no payload, use `EmptyResult`.
struct APIResponse<T: Decodable>: Decodable {
    let statusCode: String
    let status: String
    let result: T
    let message: String
}

/// Placeholder for endpoints whose envelope returns `"result": {}` with no fields.
struct EmptyResult: Decodable, Equatable {}

/// Business-layer error raised when HTTP succeeded (200 OK) but the envelope's
/// `status` field reports a failure. The HTTP layer's `NetworkError` does not
/// cover this case because, to the transport, the request succeeded.
enum APIError: Error, LocalizedError {
    case businessFailure(status: String, message: String)

    var errorDescription: String? {
        if case let .businessFailure(_, message) = self { return message }
        return nil
    }
}

// MARK: - Envelope-aware sending

extension DataTransferProtocol {
    /// Sends a request expecting the standard `APIResponse<T>` envelope, validates
    /// that `status == "success"`, and returns just the unwrapped `result`.
    ///
    /// Throws `APIError.businessFailure` when the HTTP call succeeds but the
    /// envelope reports a non-success status (so the server's `message` reaches the UI).
    func sendUnwrapped<T: Decodable, R: NetworkRequestable>(_ request: R) async throws -> T {
        let envelope: APIResponse<T> = try await send(request)
        guard envelope.status.lowercased() == "success" else {
            throw APIError.businessFailure(status: envelope.status, message: envelope.message)
        }
        return envelope.result
    }
}

// MARK: - 4. Token Provider

/// One shared `TokenProvider` for the whole app. The token is persisted in the
/// Keychain via `KeychainTokenStorage`, so it survives launches, and read /
/// write access is serialized through the actor.
///
/// Swap `KeychainTokenStorage` for `InMemoryTokenStorage()` in unit tests.
let appTokenProvider: any TokenProvider = StoredTokenProvider(
    storage: KeychainTokenStorage(service: "com.myrepcard.RepCard")
)

// MARK: - 5. Client Setup

/// Builds an `HTTPClient` configured with the auth interceptor.
///
/// The interceptor pulls the latest token from `appTokenProvider` on every
/// request, so after `login(...)` succeeds and writes the token, subsequent
/// calls automatically attach the `userToken` header.
@MainActor
func makeAuthenticatedClient() -> HTTPClient {
    HTTPClient(
        configuration: .init(
            decoder: JSONDecoder(),
            cache: ResponseCache(defaultMaxAge: 60),
            interceptors: [
                AuthTokenInterceptor(tokenProvider: appTokenProvider),
                RetryInterceptor(maxRetries: 2, delay: 0.5),
            ]
        )
    )
}

// MARK: - 6. Login / Logout flows

/// Full login flow, end-to-end.
///
/// 1. POST credentials to `/auth/login` — runs unauthenticated (`requiresAuthentication = false`).
/// 2. Persist the returned token via the `TokenProvider`.
/// 3. Any later call (e.g. `currentUser`) automatically picks the token up via the interceptor.
///
/// - Returns: The signed-in user's profile.
@MainActor
func performLogin(email: String, password: String) async throws -> AuthenticatedUser {
    let client = makeAuthenticatedClient()

    // Step 1 — exchange credentials for tokens.
    let response: LoginResponse = try await client.sendUnwrapped(
        AuthEndpoint.login(email: email, password: password)
    )

    // Step 2 — store the access token so the interceptor can find it.
    try await appTokenProvider.setToken(Token(accessToken: response.accessToken))

    // Step 3 — verify the token works by fetching the current user. The
    // `currentUser` endpoint declares `requiresAuthentication == true`, so the
    // interceptor injects the bearer header automatically.
    let me: AuthenticatedUser = try await client.sendUnwrapped(AuthEndpoint.currentUser)
    return me
}

/// Sign the user out: drop the persisted token. Anything still pointing at
/// `appTokenProvider` will throw `TokenProviderError.notAuthenticated` on the
/// next request.
func performLogout() async throws {
    try await appTokenProvider.clear()
}

/// Quick helper for splash screens that need to know whether to route the user
/// to the login flow or straight into the app.
func isUserSignedIn() async -> Bool {
    await appTokenProvider.hasToken()
}

// MARK: - 7. Error Handling Example

/// Demonstrates the typed error surface — callers can react to specific failures
/// without inspecting strings or status codes.
@MainActor
func loginWithUserFacingErrors(email: String, password: String) async -> String {
    do {
        let user = try await performLogin(email: email, password: password)
        return "Welcome, \(user.name)"
    } catch let APIError.businessFailure(_, message) {
        // HTTP succeeded but the envelope's `status` reported failure — surface the server's message.
        return message
    } catch TokenProviderError.notAuthenticated {
        // The interceptor asked the provider for a token but the user is signed out.
        return "Please sign in to continue."
    } catch NetworkError.unauthorized {
        return "Invalid email or password."
    } catch NetworkError.noInternetConnection {
        return "You appear to be offline. Check your connection and try again."
    } catch NetworkError.timeout {
        return "The server took too long to respond. Please try again."
    } catch NetworkError.serverError(let code, _) {
        return "Server error (\(code)). Please try again later."
    } catch {
        return "Something went wrong: \(error.localizedDescription)"
    }
}

