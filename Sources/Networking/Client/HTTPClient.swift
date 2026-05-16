import Combine
import Foundation

// MARK: - HTTPClient

/// URL-session-backed HTTP client.
///
/// Conforms to `DataTransferProtocol`, `UploadProtocol`, and `DownloadProtocol`.
/// All three async styles (async/await, Combine, closure) delegate through the single
/// `execute(_:)` kernel so there is exactly one code path for status validation,
/// caching, and the interceptor chain.
///
/// **Thread safety**: The client itself is stateless after `init`; all mutable state
/// lives inside `URLSession` and `CacheStorable`, both of which handle their own
/// thread safety.
public final class HTTPClient: Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var decoder: ResponseDecoderProtocol
        public var cache: CacheStorable
        public var interceptors: [RequestInterceptorProtocol]
        /// HTTP methods whose successful responses should be cached.
        public var cacheableMethods: Set<HTTPMethod>
        /// Maximum number of automatic retries driven by `RequestInterceptorProtocol.retry`.
        public var maxRetries: Int

        public init(
            decoder: ResponseDecoderProtocol = JSONDecoder(),
            cache: CacheStorable = ResponseCache(),
            interceptors: [RequestInterceptorProtocol] = [],
            cacheableMethods: Set<HTTPMethod> = [.get],
            maxRetries: Int = 3
        ) {
            self.decoder = decoder
            self.cache = cache
            self.interceptors = interceptors
            self.cacheableMethods = cacheableMethods
            self.maxRetries = maxRetries
        }

        public static var `default`: Configuration { .init() }
    }

    // MARK: - State

    private let session: URLSession
    private let configuration: Configuration

    // MARK: - Init

    public init(
        session: URLSession = .shared,
        configuration: Configuration = .default
    ) {
        self.session = session
        self.configuration = configuration
    }

    /// Convenience initialiser for quick setups.
    public convenience init(
        session: URLSession = .shared,
        decoder: ResponseDecoderProtocol = JSONDecoder(),
        cache: CacheStorable = ResponseCache(),
        interceptors: [RequestInterceptorProtocol] = []
    ) {
        self.init(
            session: session,
            configuration: .init(decoder: decoder, cache: cache, interceptors: interceptors)
        )
    }

    // MARK: - Core Execution

    /// The single code path through which every request travels.
    /// Applies the interceptor chain, checks the cache, executes the request,
    /// validates the status code, stores the result in cache, and maps errors.
    /// Primary execute kernel. `perform` receives the fully adapted request and is
    /// responsible for the URLSession call; everything else — adaptor chain, cache
    /// lookup/store, status validation, and retry — is handled here uniformly for
    /// all request types (data, upload, download).
    private func execute(
        _ urlRequest: URLRequest,
        retryCount: Int = 0,
        perform: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let adaptedRequest = try await applyAdaptors(to: urlRequest)

        // Cache look-up for cacheable methods.
        if let method = HTTPMethod(rawValue: adaptedRequest.httpMethod ?? ""),
           configuration.cacheableMethods.contains(method),
           let cached = configuration.cache.cachedResponse(for: adaptedRequest),
           let httpResponse = cached.response as? HTTPURLResponse {
            return (cached.data, httpResponse)
        }

        do {
            let (data, response) = try await perform(adaptedRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            try validate(httpResponse, data: data)

            // Store successful cacheable responses.
            if let method = HTTPMethod(rawValue: adaptedRequest.httpMethod ?? ""),
               configuration.cacheableMethods.contains(method) {
                let entry = CachedURLResponse(response: httpResponse, data: data)
                configuration.cache.storeCachedResponse(entry, for: adaptedRequest)
            }

            return (data, httpResponse)

        } catch {
            let networkError = NetworkError.map(error)
            return try await handleRetry(
                adaptedRequest,
                error: networkError,
                retryCount: retryCount,
                perform: perform
            )
        }
    }

    /// Convenience shim for plain data requests.
    private func execute(
        _ urlRequest: URLRequest,
        retryCount: Int = 0
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        try await execute(urlRequest, retryCount: retryCount) { [session] request in
            try await session.data(for: request)
        }
    }

    // MARK: - Retry

    /// Consults every interceptor and returns the longest delay any of them requests,
    /// or `nil` when all vote `.doNotRetry` or the retry budget is exhausted.
    /// Shared by both `handleRetry` (data/upload) and `executeDownload`.
    private func retryDelay(
        for request: URLRequest,
        error: NetworkError,
        retryCount: Int
    ) async -> TimeInterval? {
        guard retryCount < configuration.maxRetries else { return nil }

        // `maxDelay` stays nil when all interceptors vote .doNotRetry; any retry vote
        // sets it to at least 0, and .retryWithDelay votes push it to the longest
        // requested sleep so the most conservative interceptor's requirement is honoured.
        var maxDelay: TimeInterval?
        for interceptor in configuration.interceptors {
            switch await interceptor.retry(request, dueTo: error, currentRetryCount: retryCount) {
            case .retry:
                if maxDelay == nil { maxDelay = 0 }
            case .retryWithDelay(let delay):
                maxDelay = max(maxDelay ?? 0, delay)
            case .doNotRetry:
                break
            }
        }
        return maxDelay
    }

    private func handleRetry(
        _ request: URLRequest,
        error: NetworkError,
        retryCount: Int,
        perform: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        guard let delay = await retryDelay(for: request, error: error, retryCount: retryCount) else { throw error }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return try await execute(request, retryCount: retryCount + 1, perform: perform)
    }

    /// Download-specific kernel. Mirrors `execute` but is typed around `(URL, URLResponse)`
    /// because the response body is a file on disk, not in-memory `Data`.
    /// Cache lookup and store are intentionally omitted: caching an empty-data entry for
    /// a file download would corrupt subsequent cache hits for the same request.
    private func executeDownload(
        _ urlRequest: URLRequest,
        retryCount: Int = 0,
        perform: @escaping @Sendable (URLRequest) async throws -> (URL, URLResponse)
    ) async throws -> URL {
        let adaptedRequest = try await applyAdaptors(to: urlRequest)

        do {
            let (fileURL, response) = try await perform(adaptedRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }
            try validate(httpResponse, data: Data())
            return fileURL
        } catch {
            let networkError = NetworkError.map(error)
            guard let delay = await retryDelay(for: adaptedRequest, error: networkError, retryCount: retryCount) else {
                throw networkError
            }
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            return try await executeDownload(adaptedRequest, retryCount: retryCount + 1, perform: perform)
        }
    }

    // MARK: - Interceptor Chain

    private func applyAdaptors(to request: URLRequest) async throws -> URLRequest {
        var current = request
        for interceptor in configuration.interceptors {
            current = try await interceptor.adapt(current)
        }
        return current
    }

    // MARK: - Status Code Validation

    private func validate(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200...299: return
        case 401: throw NetworkError.unauthorized
        case 403: throw NetworkError.forbidden
        case 404: throw NetworkError.notFound
        default:  throw NetworkError.serverError(statusCode: response.statusCode, data: data)
        }
    }
}

// MARK: - DataTransferProtocol

extension HTTPClient: DataTransferProtocol {

    public func send<T: Decodable, R: NetworkRequestable>(_ request: R) async throws -> T {
        let urlRequest = try request.asURLRequest()
        let (data, _) = try await execute(urlRequest)
        do {
            return try configuration.decoder.decode(T.self, from: data)
        } catch {
            throw NetworkError.decodingFailed(error)
        }
    }

    public func sendRaw<R: NetworkRequestable>(_ request: R) async throws -> (data: Data, response: HTTPURLResponse) {
        let urlRequest = try request.asURLRequest()
        return try await execute(urlRequest)
    }

    public func send<T: Decodable, R: NetworkRequestable>(_ request: R) -> AnyPublisher<T, NetworkError> {
        Deferred {
            Future { [weak self] promise in
                guard let self else { return promise(.failure(.cancelled)) }
                Task {
                    do {
                        let value: T = try await self.send(request)
                        promise(.success(value))
                    } catch let e as NetworkError {
                        promise(.failure(e))
                    } catch {
                        promise(.failure(.unknown(error)))
                    }
                }
            }
        }
        .eraseToAnyPublisher()
    }

    @discardableResult
    public func send<T: Decodable, R: NetworkRequestable>(
        _ request: R,
        completion: @escaping @Sendable (Result<T, NetworkError>) -> Void
    ) -> NetworkCancellable {
        let task = Task { [weak self] in
            guard let self else {
                // self is nil regardless of cancellation state — the operation never
                // ran, so completion must always be invoked to avoid leaving the
                // caller permanently suspended.
                completion(.failure(.cancelled))
                return
            }
            let result: Result<T, NetworkError>
            do {
                result = .success(try await self.send(request))
            } catch let e as NetworkError {
                result = .failure(e)
            } catch {
                result = .failure(.unknown(error))
            }
            if !Task.isCancelled { completion(result) }
        }
        return TaskCancellable(task: task)
    }
}

// MARK: - UploadProtocol

extension HTTPClient: UploadProtocol {

    public func upload<T: Decodable, R: NetworkRequestable>(
        multipart: MultipartFormData,
        request: R,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> T {
        var urlRequest = try request.asURLRequest()
        urlRequest.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")

        let data: Data

        if multipart.hasFileParts {
            // Stream the assembled body to a temp file in chunks so the full multipart
            // payload is never held in RAM. The file persists for all retry attempts
            // and is removed once execute returns (success or exhausted retries).
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try multipart.encode(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            (data, _) = try await execute(urlRequest) { [session] adaptedRequest in
                let delegate = TaskProgressDelegate(uploadProgress: progressHandler)
                return try await session.upload(for: adaptedRequest, fromFile: tempURL, delegate: delegate)
            }
        } else {
            let body = try multipart.encode()
            (data, _) = try await execute(urlRequest) { [session] adaptedRequest in
                let delegate = TaskProgressDelegate(uploadProgress: progressHandler)
                return try await session.upload(for: adaptedRequest, from: body, delegate: delegate)
            }
        }

        do {
            return try configuration.decoder.decode(T.self, from: data)
        } catch {
            throw NetworkError.decodingFailed(error)
        }
    }

    public func upload<T: Decodable, R: NetworkRequestable>(
        multipart: MultipartFormData,
        request: R,
        progressHandler: (@Sendable (Double) -> Void)?
    ) -> AnyPublisher<T, NetworkError> {
        Deferred {
            Future { [weak self] promise in
                guard let self else { return promise(.failure(.cancelled)) }
                Task {
                    do {
                        let value: T = try await self.upload(
                            multipart: multipart,
                            request: request,
                            progressHandler: progressHandler
                        )
                        promise(.success(value))
                    } catch let e as NetworkError {
                        promise(.failure(e))
                    } catch {
                        promise(.failure(.unknown(error)))
                    }
                }
            }
        }
        .eraseToAnyPublisher()
    }

    @discardableResult
    public func upload<T: Decodable, R: NetworkRequestable>(
        multipart: MultipartFormData,
        request: R,
        progressHandler: (@Sendable (Double) -> Void)?,
        completion: @escaping @Sendable (Result<T, NetworkError>) -> Void
    ) -> NetworkCancellable {
        let task = Task { [weak self] in
            guard let self else {
                completion(.failure(.cancelled))
                return
            }
            let result: Result<T, NetworkError>
            do {
                result = .success(try await self.upload(
                    multipart: multipart,
                    request: request,
                    progressHandler: progressHandler
                ))
            } catch let e as NetworkError {
                result = .failure(e)
            } catch {
                result = .failure(.unknown(error))
            }
            if !Task.isCancelled { completion(result) }
        }
        return TaskCancellable(task: task)
    }
}

// MARK: - DownloadProtocol

extension HTTPClient: DownloadProtocol {

    public func download<R: NetworkRequestable>(
        _ request: R,
        destination: URL?,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let urlRequest = try request.asURLRequest()
        return try await executeDownload(urlRequest) { [session] adaptedRequest in
            let delegate = TaskProgressDelegate(downloadProgress: progressHandler)
            let (tempURL, response) = try await session.download(for: adaptedRequest, delegate: delegate)
            guard let dest = destination else { return (tempURL, response) }
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
            return (dest, response)
        }
    }

    public func download<R: NetworkRequestable>(
        _ request: R,
        destination: URL?,
        progressHandler: (@Sendable (Double) -> Void)?
    ) -> AnyPublisher<URL, NetworkError> {
        Deferred {
            Future { [weak self] promise in
                guard let self else { return promise(.failure(.cancelled)) }
                Task {
                    do {
                        let url = try await self.download(
                            request,
                            destination: destination,
                            progressHandler: progressHandler
                        )
                        promise(.success(url))
                    } catch let e as NetworkError {
                        promise(.failure(e))
                    } catch {
                        promise(.failure(.unknown(error)))
                    }
                }
            }
        }
        .eraseToAnyPublisher()
    }

    @discardableResult
    public func download<R: NetworkRequestable>(
        _ request: R,
        destination: URL?,
        progressHandler: (@Sendable (Double) -> Void)?,
        completion: @escaping @Sendable (Result<URL, NetworkError>) -> Void
    ) -> NetworkCancellable {
        let task = Task { [weak self] in
            guard let self else {
                completion(.failure(.cancelled))
                return
            }
            let result: Result<URL, NetworkError>
            do {
                result = .success(try await self.download(
                    request,
                    destination: destination,
                    progressHandler: progressHandler
                ))
            } catch let e as NetworkError {
                result = .failure(e)
            } catch {
                result = .failure(.unknown(error))
            }
            if !Task.isCancelled { completion(result) }
        }
        return TaskCancellable(task: task)
    }
}

// MARK: - TaskProgressDelegate

/// Per-task delegate injected via the iOS 15 `delegate:` parameter on URLSession async methods.
/// Reports upload and download progress without requiring a session-level delegate.
///
/// `@unchecked Sendable` is required because `NSObject` is itself `@unchecked Sendable` and
/// that annotation cannot be narrowed in a subclass. The conformance is safe: each instance is
/// created immediately before a single async URLSession call and is never stored or shared
/// across tasks. Both added stored properties are `@Sendable` closures.
private final class TaskProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {

    private let uploadProgress: (@Sendable (Double) -> Void)?
    private let downloadProgress: (@Sendable (Double) -> Void)?

    init(
        uploadProgress: (@Sendable (Double) -> Void)? = nil,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
    ) {
        self.uploadProgress = uploadProgress
        self.downloadProgress = downloadProgress
    }

    // Upload progress
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        uploadProgress?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    // Download progress
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        downloadProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // Required by URLSessionDownloadDelegate; not used because the async API handles the URL.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
