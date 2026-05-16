# Networking

A small, dependency-free HTTP layer for Swift. Protocol-oriented, fully `Sendable`,
async/await first, and trivially testable thanks to `MockURLProtocol` /
`MockHTTPClient` in the companion `NetworkTesting` library.

## Highlights

- Type-safe endpoints described once via a single `NetworkRequestable` protocol.
- async/await first, with a `Combine` publisher and closure variants on top.
- Multipart upload + file download, both with progress reporting.
- Background download manager that survives suspension.
- Pluggable response cache.
- Interceptor pipeline for auth headers, retries, logging, etc.
- Bearer-token plumbing (`TokenProvider` + `KeychainTokenStorage`) ready to drop in.

## Requirements

| | |
|---|---|
| Swift | 5.9+ |
| iOS | 15.0+ |
| macOS | 12.0+ |

## Installation

Add the package to your project's `Package.swift`:

```swift
.package(url: "https://github.com/your-org/Networking.git", from: "1.0.0")
```

Then add `Networking` to whichever app/feature targets need it, and `NetworkTesting`
to your test targets only.

```swift
.target(
    name: "MyApp",
    dependencies: [.product(name: "Networking", package: "Networking")]
),
.testTarget(
    name: "MyAppTests",
    dependencies: [
        "MyApp",
        .product(name: "NetworkTesting", package: "Networking"),
    ]
)
```

---

The complete walkthrough below is mirrored in [`example.swift`](example.swift) at
the package root. Copy whatever you need into your own target.

## 1. Models

```swift
struct LoginRequest: Encodable, Sendable {
    let email: String
    let password: String
}

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
```

## 2. Endpoints

Group every call for a feature into a single `enum` so they share a base URL,
auth policy, decoding rules, and so on.

```swift
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
```

## 3. A response envelope

Most APIs wrap every payload in a "status / message / result" envelope. Define
it once and add a small `DataTransferProtocol` extension that unwraps it.

```swift
struct APIResponse<T: Decodable>: Decodable {
    let statusCode: String
    let status: String
    let result: T
    let message: String
}

/// Placeholder for endpoints whose envelope returns `"result": {}` with no fields.
struct EmptyResult: Decodable, Equatable {}

enum APIError: Error, LocalizedError {
    case businessFailure(status: String, message: String)

    var errorDescription: String? {
        if case let .businessFailure(_, message) = self { return message }
        return nil
    }
}

extension DataTransferProtocol {
    /// Sends a request expecting the standard `APIResponse<T>` envelope, validates
    /// that `status == "success"`, and returns just the unwrapped `result`.
    func sendUnwrapped<T: Decodable, R: NetworkRequestable>(_ request: R) async throws -> T {
        let envelope: APIResponse<T> = try await send(request)
        guard envelope.status.lowercased() == "success" else {
            throw APIError.businessFailure(status: envelope.status, message: envelope.message)
        }
        return envelope.result
    }
}
```

## 4. Token provider

`StoredTokenProvider` + `KeychainTokenStorage` handle the bearer-token side of
auth. The provider is an `actor`, so reads and writes are race-free.

```swift
let appTokenProvider: any TokenProvider = StoredTokenProvider(
    storage: KeychainTokenStorage(service: "com.myrepcard.RepCard")
)
```

For tests / SwiftUI previews, swap in `InMemoryTokenStorage()`.

## 5. Client setup

```swift
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
```

The auth interceptor only attaches a token to endpoints whose
`requiresAuthentication == true`, so anonymous endpoints (sign-in, sign-up…)
are sent untouched.

## 6. Login / logout flows

```swift
@MainActor
func performLogin(email: String, password: String) async throws -> AuthenticatedUser {
    let client = makeAuthenticatedClient()

    // 1 — exchange credentials for tokens.
    let response: LoginResponse = try await client.sendUnwrapped(
        AuthEndpoint.login(email: email, password: password)
    )

    // 2 — store the access token so the interceptor can find it.
    try await appTokenProvider.setToken(Token(accessToken: response.accessToken))

    // 3 — verify the token works by fetching the current user.
    let me: AuthenticatedUser = try await client.sendUnwrapped(AuthEndpoint.currentUser)
    return me
}

func performLogout() async throws {
    try await appTokenProvider.clear()
}

func isUserSignedIn() async -> Bool {
    await appTokenProvider.hasToken()
}
```

## 7. User-facing error handling

`NetworkError` is fully typed, so call sites can react to specific failures
without parsing strings.

```swift
@MainActor
func loginWithUserFacingErrors(email: String, password: String) async -> String {
    do {
        let user = try await performLogin(email: email, password: password)
        return "Welcome, \(user.name)"
    } catch let APIError.businessFailure(_, message) {
        return message
    } catch TokenProviderError.notAuthenticated {
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
```

## Testing

`NetworkTesting` ships with two helpers you can use right away:

| Helper | When to use it |
|---|---|
| `MockURLProtocol` | End-to-end testing of a real `HTTPClient` — register canned responses for a URL and Networking talks to a fake `URLSession`. |
| `MockHTTPClient`  | Unit-testing higher-level types (view models, services). Inject the mock in place of the real client. |

```swift
import Networking
import NetworkTesting
import XCTest

final class AuthServiceTests: XCTestCase {
    func test_login_persistsToken() async throws {
        let client = MockHTTPClient()
        client.stub(AuthEndpoint.login(email: "a", password: "b"),
                    with: APIResponse(statusCode: "200",
                                      status: "success",
                                      result: LoginResponse.fixture(),
                                      message: ""))

        let provider = StoredTokenProvider(storage: InMemoryTokenStorage())
        let service  = AuthService(client: client, tokenProvider: provider)

        _ = try await service.login(email: "a", password: "b")
        let stored = await provider.hasToken()
        XCTAssertTrue(stored)
    }
}
```

## License

MIT. See [LICENSE](LICENSE).
