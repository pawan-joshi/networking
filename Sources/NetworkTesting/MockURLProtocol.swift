import Foundation
import NetworkLayer

// MARK: - MockURLProtocol

/// A `URLProtocol` subclass that intercepts every request and returns a
/// pre-programmed response — no real network traffic is made.
///
/// ## Usage
///
/// ```swift
/// // 1. Configure the mock before each test:
/// MockURLProtocol.requestHandler = { request in
///     let response = HTTPURLResponse(
///         url: request.url!,
///         statusCode: 200,
///         httpVersion: nil,
///         headerFields: ["Content-Type": "application/json"]
///     )!
///     let data = try JSONEncoder().encode(MyModel(id: 1, name: "Alice"))
///     return (response, data)
/// }
///
/// // 2. Wire it into a URLSession:
/// let config = URLSessionConfiguration.ephemeral
/// config.protocolClasses = [MockURLProtocol.self]
/// let session = URLSession(configuration: config)
///
/// // 3. Inject the session into HTTPClient:
/// let client = HTTPClient(session: session)
/// ```
public final class MockURLProtocol: URLProtocol {

    // MARK: - Shared State

    /// Set this before each test. Throw `NetworkError` (or any `Error`) to simulate failures.
    public static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    /// Simulated network delay in seconds. Set to 0 (default) for instant responses.
    public static var responseDelay: TimeInterval = 0

    // MARK: - URLProtocol

    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: MockError.noHandlerRegistered)
            return
        }

        let delay = MockURLProtocol.responseDelay
        let capturedRequest = request
        let capturedClient = client

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            do {
                let (response, data) = try handler(capturedRequest)
                capturedClient?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if let data { capturedClient?.urlProtocol(self, didLoad: data) }
                capturedClient?.urlProtocolDidFinishLoading(self)
            } catch {
                capturedClient?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override public func stopLoading() {}

    // MARK: - Reset

    /// Call in `tearDown` to avoid test pollution.
    public static func reset() {
        requestHandler = nil
        responseDelay = 0
    }
}

// MARK: - MockError

public enum MockError: Error, LocalizedError {
    case noHandlerRegistered
    case custom(String)

    public var errorDescription: String? {
        switch self {
        case .noHandlerRegistered: return "MockURLProtocol.requestHandler was not set."
        case .custom(let msg):     return msg
        }
    }
}

// MARK: - URLSession Factory

public extension URLSession {
    /// Creates a `URLSession` backed by `MockURLProtocol`, ready for injection into `HTTPClient`.
    static func makeMocked() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
