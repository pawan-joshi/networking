import Combine
import Foundation
import Networking

// MARK: - MockHTTPClient

/// A fully in-memory implementation of `DataTransferProtocol`, `UploadProtocol`,
/// and `DownloadProtocol` for unit testing call-sites that depend on the client.
///
/// Configure `sendResult`, `uploadResult`, and `downloadResult` before each test.
/// Inspect `capturedRequests`, `capturedUploads`, and `capturedDownloads` afterwards.
public final class MockHTTPClient: @unchecked Sendable {

    // MARK: - Stubbed Responses

    /// Set to `.success(value)` or `.failure(error)` before calling `send`.
    public var sendResult: (any Sendable)?

    public var uploadResult: (any Sendable)?

    public var downloadResult: Result<URL, NetworkError> = .success(
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mock.bin")
    )

    // MARK: - Captured Calls (for assertions)

    public private(set) var capturedRequests: [any NetworkRequestable] = []
    public private(set) var capturedUploads: [(multipart: MultipartFormData, request: any NetworkRequestable)] = []
    public private(set) var capturedDownloads: [any NetworkRequestable] = []

    // MARK: - Init

    public init() {}

    // MARK: - Reset

    public func reset() {
        sendResult = nil
        uploadResult = nil
        downloadResult = .success(
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mock.bin")
        )
        capturedRequests.removeAll()
        capturedUploads.removeAll()
        capturedDownloads.removeAll()
    }
}

// MARK: - DataTransferProtocol

extension MockHTTPClient: DataTransferProtocol {

    public func send<T: Decodable, R: NetworkRequestable>(_ request: R) async throws -> T {
        capturedRequests.append(request)
        guard let result = sendResult as? T else {
            throw NetworkError.noData
        }
        return result
    }

    public func sendRaw<R: NetworkRequestable>(_ request: R) async throws -> (data: Data, response: HTTPURLResponse) {
        capturedRequests.append(request)
        let response = HTTPURLResponse(
            url: URL(string: "https://mock.test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (sendResult as? Data ?? Data(), response)
    }

    public func send<T: Decodable, R: NetworkRequestable>(_ request: R) -> AnyPublisher<T, NetworkError> {
        capturedRequests.append(request)
        if let value = sendResult as? T {
            return Just(value)
                .setFailureType(to: NetworkError.self)
                .eraseToAnyPublisher()
        }
        return Fail(error: NetworkError.noData).eraseToAnyPublisher()
    }

    @discardableResult
    public func send<T: Decodable, R: NetworkRequestable>(
        _ request: R,
        completion: @escaping @Sendable (Result<T, NetworkError>) -> Void
    ) -> NetworkCancellable {
        capturedRequests.append(request)
        if let value = sendResult as? T {
            completion(.success(value))
        } else {
            completion(.failure(.noData))
        }
        return VoidCancellable()
    }
}

// MARK: - UploadProtocol

extension MockHTTPClient: UploadProtocol {

    public func upload<T: Decodable, R: NetworkRequestable>(
        multipart: MultipartFormData,
        request: R,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> T {
        capturedUploads.append((multipart, request))
        progressHandler?(1.0)
        guard let result = uploadResult as? T else { throw NetworkError.noData }
        return result
    }

    public func upload<T: Decodable, R: NetworkRequestable>(
        multipart: MultipartFormData,
        request: R,
        progressHandler: (@Sendable (Double) -> Void)?
    ) -> AnyPublisher<T, NetworkError> {
        capturedUploads.append((multipart, request))
        progressHandler?(1.0)
        if let value = uploadResult as? T {
            return Just(value).setFailureType(to: NetworkError.self).eraseToAnyPublisher()
        }
        return Fail(error: NetworkError.noData).eraseToAnyPublisher()
    }

    @discardableResult
    public func upload<T: Decodable, R: NetworkRequestable>(
        multipart: MultipartFormData,
        request: R,
        progressHandler: (@Sendable (Double) -> Void)?,
        completion: @escaping @Sendable (Result<T, NetworkError>) -> Void
    ) -> NetworkCancellable {
        capturedUploads.append((multipart, request))
        progressHandler?(1.0)
        if let value = uploadResult as? T {
            completion(.success(value))
        } else {
            completion(.failure(.noData))
        }
        return VoidCancellable()
    }
}

// MARK: - DownloadProtocol

extension MockHTTPClient: DownloadProtocol {

    public func download<R: NetworkRequestable>(
        _ request: R,
        destination: URL?,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        capturedDownloads.append(request)
        progressHandler?(1.0)
        return try downloadResult.get()
    }

    public func download<R: NetworkRequestable>(
        _ request: R,
        destination: URL?,
        progressHandler: (@Sendable (Double) -> Void)?
    ) -> AnyPublisher<URL, NetworkError> {
        capturedDownloads.append(request)
        progressHandler?(1.0)
        return downloadResult.publisher.eraseToAnyPublisher()
    }

    @discardableResult
    public func download<R: NetworkRequestable>(
        _ request: R,
        destination: URL?,
        progressHandler: (@Sendable (Double) -> Void)?,
        completion: @escaping @Sendable (Result<URL, NetworkError>) -> Void
    ) -> NetworkCancellable {
        capturedDownloads.append(request)
        progressHandler?(1.0)
        completion(downloadResult)
        return VoidCancellable()
    }
}
