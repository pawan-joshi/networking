import Combine
import Foundation

/// Multipart file-upload capability with per-task progress reporting.
public protocol UploadProtocol: AnyObject, Sendable {

    // MARK: Async / Await

    /// Uploads multipart form data and decodes the server's response into `T`.
    /// - Parameters:
    ///   - multipart: The assembled multipart body.
    ///   - request: The endpoint descriptor (method should be POST/PUT/PATCH).
    ///   - progressHandler: Called repeatedly on a background thread with 0.0–1.0 upload fraction.
    func upload<T: Decodable, R: NetworkRequestable>(
        multipart: MultipartFormData,
        request: R,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> T

    // MARK: Combine

    /// Returns a publisher that emits the decoded response when the upload finishes.
    func upload<T: Decodable, R: NetworkRequestable>(
        multipart: MultipartFormData,
        request: R,
        progressHandler: (@Sendable (Double) -> Void)?
    ) -> AnyPublisher<T, NetworkError>

    // MARK: Closure

    /// Starts the upload and delivers the decoded result via a completion handler.
    @discardableResult
    func upload<T: Decodable, R: NetworkRequestable>(
        multipart: MultipartFormData,
        request: R,
        progressHandler: (@Sendable (Double) -> Void)?,
        completion: @escaping @Sendable (Result<T, NetworkError>) -> Void
    ) -> NetworkCancellable
}
