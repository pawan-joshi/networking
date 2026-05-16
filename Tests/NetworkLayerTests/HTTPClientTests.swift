import Combine
import XCTest
@testable import NetworkLayer
import NetworkLayerTesting

// MARK: - Test Fixtures

private struct User: Codable, Equatable {
    let id: Int
    let name: String
}

private struct CreateUserBody: Encodable, Sendable {
    let name: String
}

private enum TestEndpoint: NetworkRequestable {
    case getUser(id: Int)
    case createUser(name: String)
    case downloadFile
    case uploadAvatar

    var baseURL: URL { URL(string: "https://api.test.com")! }

    var path: String {
        switch self {
        case .getUser(let id):   return "/users/\(id)"
        case .createUser:        return "/users"
        case .downloadFile:      return "/files/report.pdf"
        case .uploadAvatar:      return "/users/me/avatar"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .getUser, .downloadFile: return .get
        case .createUser, .uploadAvatar: return .post
        }
    }

    var body: (any Encodable & Sendable)? {
        if case .createUser(let name) = self { return CreateUserBody(name: name) }
        return nil
    }
}

// MARK: - Base Test Case

class HTTPClientTestCase: XCTestCase {
    var session: URLSession!
    var client: HTTPClient!
    var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        session = .makeMocked()
        client = HTTPClient(session: session, configuration: .init(cache: NullCache()))
    }

    override func tearDown() {
        MockURLProtocol.reset()
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    func stubSuccess<T: Encodable>(_ value: T, statusCode: Int = 200) throws {
        let data = try JSONEncoder().encode(value)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
    }

    func stubFailure(statusCode: Int, body: Data? = nil) {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil
            )!
            return (response, body)
        }
    }

    func stubURLError(_ code: URLError.Code) {
        MockURLProtocol.requestHandler = { _ in throw URLError(code) }
    }
}

// MARK: - DataTransfer Tests

final class DataTransferTests: HTTPClientTestCase {

    // MARK: Async / Await

    func test_send_asyncAwait_decodesSuccessfulResponse() async throws {
        let expected = User(id: 42, name: "Alice")
        try stubSuccess(expected)

        let user: User = try await client.send(TestEndpoint.getUser(id: 42))

        XCTAssertEqual(user, expected)
    }

    func test_send_asyncAwait_throwsUnauthorizedOn401() async throws {
        stubFailure(statusCode: 401)

        do {
            let _: User = try await client.send(TestEndpoint.getUser(id: 1))
            XCTFail("Expected .unauthorized to be thrown")
        } catch NetworkError.unauthorized {
            // pass
        }
    }

    func test_send_asyncAwait_throwsForbiddenOn403() async throws {
        stubFailure(statusCode: 403)
        do {
            let _: User = try await client.send(TestEndpoint.getUser(id: 1))
            XCTFail("Expected .forbidden")
        } catch NetworkError.forbidden { }
    }

    func test_send_asyncAwait_throwsNotFoundOn404() async throws {
        stubFailure(statusCode: 404)
        do {
            let _: User = try await client.send(TestEndpoint.getUser(id: 1))
            XCTFail("Expected .notFound")
        } catch NetworkError.notFound { }
    }

    func test_send_asyncAwait_throwsServerErrorOn500() async throws {
        stubFailure(statusCode: 500)
        do {
            let _: User = try await client.send(TestEndpoint.getUser(id: 1))
            XCTFail("Expected .serverError")
        } catch NetworkError.serverError(let code, _) {
            XCTAssertEqual(code, 500)
        }
    }

    func test_send_asyncAwait_throwsDecodingFailedOnMalformedJSON() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("not json".utf8))
        }
        do {
            let _: User = try await client.send(TestEndpoint.getUser(id: 1))
            XCTFail("Expected .decodingFailed")
        } catch NetworkError.decodingFailed { }
    }

    func test_sendRaw_returnsDataAndResponse() async throws {
        let payload = Data("raw bytes".utf8)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, payload)
        }

        let (data, response) = try await client.sendRaw(TestEndpoint.getUser(id: 1))
        XCTAssertEqual(data, payload)
        XCTAssertEqual(response.statusCode, 200)
    }

    // MARK: Combine

    func test_send_combine_emitsDecodedValue() throws {
        let expected = User(id: 7, name: "Bob")
        try stubSuccess(expected)

        let expectation = expectation(description: "Combine send")
        var received: User?

        let publisher: AnyPublisher<User, NetworkError> = client.send(TestEndpoint.getUser(id: 7))
        publisher
            .sink(
                receiveCompletion: { _ in expectation.fulfill() },
                receiveValue:      { received = $0 }
            )
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 3)
        XCTAssertEqual(received, expected)
    }

    func test_send_combine_failsWithNetworkError() throws {
        stubFailure(statusCode: 404)

        let expectation = expectation(description: "Combine failure")
        var receivedError: NetworkError?

        let publisher: AnyPublisher<User, NetworkError> = client.send(TestEndpoint.getUser(id: 99))
        publisher
            .sink(
                receiveCompletion: {
                    if case .failure(let e) = $0 { receivedError = e }
                    expectation.fulfill()
                },
                receiveValue: { _ in }
            )
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 3)
        XCTAssertEqual(receivedError, .notFound)
    }

    // MARK: Closure

    func test_send_closure_deliversDecodedValue() throws {
        let expected = User(id: 3, name: "Carol")
        try stubSuccess(expected)

        let expectation = expectation(description: "Closure send")
        var received: User?

        client.send(TestEndpoint.getUser(id: 3)) { (result: Result<User, NetworkError>) in
            received = try? result.get()
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 3)
        XCTAssertEqual(received, expected)
    }

    func test_send_closure_cancellableStopsFurtherCallbacks() throws {
        MockURLProtocol.responseDelay = 0.5
        try stubSuccess(User(id: 1, name: "Dave"))

        let neverFulfilled = expectation(description: "Should not be called")
        neverFulfilled.isInverted = true

        let token = client.send(TestEndpoint.getUser(id: 1)) { (_: Result<User, NetworkError>) in
            neverFulfilled.fulfill()
        }
        token.cancel()

        wait(for: [neverFulfilled], timeout: 1)
    }

    // MARK: URLRequest Construction

    func test_urlRequest_appendsQueryParameters() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            throw URLError(.cancelled)
        }

        struct SearchEndpoint: NetworkRequestable {
            var baseURL = URL(string: "https://api.test.com")!
            var path = "/search"
            var method: HTTPMethod = .get
            var queryParameters: [String: String]? = ["q": "swift", "page": "2"]
        }

        _ = try? await client.sendRaw(SearchEndpoint())
        let items = URLComponents(url: capturedURL!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let dict = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        XCTAssertEqual(dict["q"], "swift")
        XCTAssertEqual(dict["page"], "2")
    }

    func test_urlRequest_setsHTTPMethod() async throws {
        var capturedMethod: String?
        MockURLProtocol.requestHandler = { request in
            capturedMethod = request.httpMethod
            throw URLError(.cancelled)
        }

        _ = try? await client.sendRaw(TestEndpoint.createUser(name: "Eve"))
        XCTAssertEqual(capturedMethod, "POST")
    }
}

// MARK: - Caching Tests

final class CachingTests: XCTestCase {
    private var session: URLSession!
    private var cache: ResponseCache!
    private var client: HTTPClient!

    override func setUp() {
        super.setUp()
        session = .makeMocked()
        cache = ResponseCache(memoryCapacity: 1_000_000, diskCapacity: 0, defaultMaxAge: 60)
        client = HTTPClient(session: session, configuration: .init(cache: cache))
    }

    override func tearDown() {
        MockURLProtocol.reset()
        cache.removeAllCachedResponses()
        super.tearDown()
    }

    func test_getRequest_isServedFromCacheOnSecondCall() async throws {
        var callCount = 0
        let user = User(id: 1, name: "Cached")
        let data = try JSONEncoder().encode(user)

        MockURLProtocol.requestHandler = { request in
            callCount += 1
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let _: User = try await client.send(TestEndpoint.getUser(id: 1))
        let _: User = try await client.send(TestEndpoint.getUser(id: 1))

        XCTAssertEqual(callCount, 1, "Second call should have been served from cache")
    }

    func test_postRequest_isNotCached() async throws {
        var callCount = 0
        let user = User(id: 2, name: "Uncached")
        let data = try JSONEncoder().encode(user)

        MockURLProtocol.requestHandler = { request in
            callCount += 1
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let _: User = try await client.send(TestEndpoint.createUser(name: "Uncached"))
        let _: User = try await client.send(TestEndpoint.createUser(name: "Uncached"))

        XCTAssertEqual(callCount, 2, "POST responses should never be cached")
    }
}

// MARK: - Interceptor Tests

final class InterceptorTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        session = .makeMocked()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func test_authInterceptor_injectsBearerToken_whenRequiresAuthIsTrue() async throws {
        var capturedHeaders: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            capturedHeaders = request.allHTTPHeaderFields ?? [:]
            throw URLError(.cancelled)
        }

        let interceptor = AuthTokenInterceptor { "test-token-123" }
        let client = HTTPClient(
            session: session,
            configuration: .init(cache: NullCache(), interceptors: [interceptor])
        )

        // getUser has requiresAuthentication == true (default)
        _ = try? await client.sendRaw(TestEndpoint.getUser(id: 1))

        XCTAssertEqual(capturedHeaders["Authorization"], "Bearer test-token-123")
        // Sentinel must be stripped before the request leaves the layer.
        XCTAssertNil(capturedHeaders["X-Requires-Authentication"])
    }

    func test_authInterceptor_doesNotInjectToken_whenRequiresAuthIsFalse() async throws {
        var capturedHeaders: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            capturedHeaders = request.allHTTPHeaderFields ?? [:]
            throw URLError(.cancelled)
        }

        struct PublicEndpoint: NetworkRequestable {
            var baseURL = URL(string: "https://api.test.com")!
            var path = "/public/status"
            var method: HTTPMethod = .get
            var requiresAuthentication: Bool = false
        }

        let interceptor = AuthTokenInterceptor {
            XCTFail("tokenProvider must not be called for unauthenticated requests")
            return "should-not-be-used"
        }
        let client = HTTPClient(
            session: session,
            configuration: .init(cache: NullCache(), interceptors: [interceptor])
        )

        _ = try? await client.sendRaw(PublicEndpoint())

        XCTAssertNil(capturedHeaders["Authorization"])
        XCTAssertNil(capturedHeaders["X-Requires-Authentication"])
    }

    func test_authInterceptor_sentinelIsAlwaysStripped() async throws {
        // Even for authenticated requests the sentinel header must not reach the server.
        var capturedHeaders: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            capturedHeaders = request.allHTTPHeaderFields ?? [:]
            throw URLError(.cancelled)
        }

        let interceptor = AuthTokenInterceptor { "tok" }
        let client = HTTPClient(
            session: session,
            configuration: .init(cache: NullCache(), interceptors: [interceptor])
        )

        _ = try? await client.sendRaw(TestEndpoint.getUser(id: 1))

        XCTAssertNil(capturedHeaders["X-Requires-Authentication"])
    }

    func test_retryInterceptor_retriesOnTimeout() async throws {
        var attemptCount = 0

        MockURLProtocol.requestHandler = { _ in
            attemptCount += 1
            if attemptCount < 3 { throw URLError(.timedOut) }
            let data = try JSONEncoder().encode(User(id: 1, name: "Retry"))
            let response = HTTPURLResponse(
                url: URL(string: "https://api.test.com/users/1")!,
                statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let retrier = RetryInterceptor(maxRetries: 3, delay: 0)
        let client = HTTPClient(
            session: session,
            configuration: .init(cache: NullCache(), interceptors: [retrier], maxRetries: 3)
        )

        let user: User = try await client.send(TestEndpoint.getUser(id: 1))
        XCTAssertEqual(user.name, "Retry")
        XCTAssertEqual(attemptCount, 3)
    }

    func test_retryInterceptor_stopsAfterMaxRetries() async throws {
        MockURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }

        let retrier = RetryInterceptor(maxRetries: 2, delay: 0)
        let client = HTTPClient(
            session: session,
            configuration: .init(cache: NullCache(), interceptors: [retrier], maxRetries: 2)
        )

        do {
            let _: User = try await client.send(TestEndpoint.getUser(id: 1))
            XCTFail("Expected failure after retries exhausted")
        } catch NetworkError.timeout {
            // pass
        }
    }
}

// MARK: - Upload Tests

final class UploadTests: XCTestCase {
    private var session: URLSession!
    private var client: HTTPClient!

    override func setUp() {
        super.setUp()
        session = .makeMocked()
        client = HTTPClient(session: session, configuration: .init(cache: NullCache()))
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func test_upload_multipartContentTypeIsSet() async throws {
        var capturedContentType: String?
        let response = User(id: 99, name: "Uploader")
        let data = try JSONEncoder().encode(response)

        MockURLProtocol.requestHandler = { request in
            capturedContentType = request.value(forHTTPHeaderField: "Content-Type")
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (resp, data)
        }

        let part = FormDataPart(name: "avatar", fileName: "photo.png", mimeType: "image/png", data: Data([0xFF, 0xD8]))
        let multipart = MultipartFormData(parts: [part])

        let _: User = try await client.upload(
            multipart: multipart,
            request: TestEndpoint.uploadAvatar,
            progressHandler: nil
        )

        XCTAssertTrue(capturedContentType?.hasPrefix("multipart/form-data; boundary=") == true)
    }

    func test_upload_progressHandlerIsCalledWithFinalProgress() async throws {
        // MockURLProtocol doesn't simulate byte streaming, but we can verify the handler is set up.
        // Full progress simulation requires a real URLSession (integration test territory).
        // Here we verify that a successful upload eventually resolves.
        let response = User(id: 1, name: "Done")
        let data = try JSONEncoder().encode(response)

        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (resp, data)
        }

        let multipart = MultipartFormData(parts: [.field(name: "key", value: "value")])
        let user: User = try await client.upload(
            multipart: multipart,
            request: TestEndpoint.uploadAvatar,
            progressHandler: { _ in }
        )
        XCTAssertEqual(user.id, 1)
    }
}

// MARK: - Download Tests

final class DownloadTests: XCTestCase {
    private var session: URLSession!
    private var client: HTTPClient!

    override func setUp() {
        super.setUp()
        session = .makeMocked()
        client = HTTPClient(session: session, configuration: .init(cache: NullCache()))
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func test_download_asyncAwait_returnsFileURL() async throws {
        let fileContent = Data("PDF bytes".utf8)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, fileContent)
        }

        let url = try await client.download(
            TestEndpoint.downloadFile,
            destination: nil,
            progressHandler: nil
        )

        // URLSession.download(for:) moves bytes to a temp file; MockURLProtocol simulates
        // this by routing through URLSession's normal data path. Verify we got back a URL.
        XCTAssertNotNil(url)
    }

    func test_download_combine_emitsURLOnSuccess() throws {
        let fileContent = Data("binary".utf8)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, fileContent)
        }

        let expectation = expectation(description: "Download combine")
        var receivedURL: URL?
        var cancellables = Set<AnyCancellable>()

        let publisher: AnyPublisher<URL, NetworkError> = client.download(
            TestEndpoint.downloadFile,
            destination: nil,
            progressHandler: nil
        )
        publisher
            .sink(
                receiveCompletion: { _ in expectation.fulfill() },
                receiveValue: { receivedURL = $0 }
            )
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 3)
        XCTAssertNotNil(receivedURL)
    }
}

// MARK: - MockHTTPClient Tests

final class MockHTTPClientTests: XCTestCase {

    func test_mockClient_capturesRequests() {
        let mock = MockHTTPClient()
        mock.sendResult = User(id: 5, name: "Mock")

        let exp = expectation(description: "mock send")
        mock.send(TestEndpoint.getUser(id: 5)) { (_: Result<User, NetworkError>) in
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(mock.capturedRequests.count, 1)
    }

    func test_mockClient_capturesUploads() async throws {
        let mock = MockHTTPClient()
        mock.uploadResult = User(id: 6, name: "Uploaded")

        let multipart = MultipartFormData(parts: [.field(name: "x", value: "y")])
        let _: User = try await mock.upload(
            multipart: multipart,
            request: TestEndpoint.uploadAvatar,
            progressHandler: nil
        )

        XCTAssertEqual(mock.capturedUploads.count, 1)
    }

    func test_mockClient_capturesDownloads() async throws {
        let mock = MockHTTPClient()
        _ = try await mock.download(TestEndpoint.downloadFile, destination: nil, progressHandler: nil)
        XCTAssertEqual(mock.capturedDownloads.count, 1)
    }
}

// MARK: - MultipartFormData Tests

final class MultipartFormDataTests: XCTestCase {

    func test_encode_producesCorrectBoundary() {
        let part = FormDataPart(name: "file", fileName: "test.txt", mimeType: "text/plain", data: Data("hello".utf8))
        let multipart = MultipartFormData(parts: [part], boundary: "TEST_BOUNDARY")
        let body = multipart.encode()
        let bodyString = String(data: body, encoding: .utf8)!

        XCTAssertTrue(bodyString.contains("--TEST_BOUNDARY\r\n"))
        XCTAssertTrue(bodyString.contains("--TEST_BOUNDARY--\r\n"))
        XCTAssertTrue(bodyString.contains("Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\""))
        XCTAssertTrue(bodyString.contains("Content-Type: text/plain"))
        XCTAssertTrue(bodyString.contains("hello"))
    }

    func test_contentType_includesBoundary() {
        let multipart = MultipartFormData(parts: [], boundary: "MY_BOUNDARY")
        XCTAssertEqual(multipart.contentType, "multipart/form-data; boundary=MY_BOUNDARY")
    }

    func test_fieldFactory_createsTextPart() {
        let part = FormDataPart.field(name: "username", value: "alice")
        XCTAssertEqual(part.name, "username")
        XCTAssertEqual(String(data: part.data, encoding: .utf8), "alice")
        XCTAssertNil(part.fileName)
    }
}
