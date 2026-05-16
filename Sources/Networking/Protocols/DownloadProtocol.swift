import Combine
import Foundation

/// Foreground file-download capability with per-task progress reporting.
/// For background downloads (app suspended / terminated), see `BackgroundDownloadManager`.
public protocol DownloadProtocol: AnyObject, Sendable {

    // MARK: Async / Await

    /// Downloads the resource described by `request` and returns the local file URL.
    /// - Parameters:
    ///   - request: The endpoint descriptor.
    ///   - destination: Where to move the finished file. Pass `nil` to keep the system temp URL.
    ///   - progressHandler: Called repeatedly on a background thread with 0.0–1.0 download fraction.
    func download<R: NetworkRequestable>(
        _ request: R,
        destination: URL?,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> URL

    // MARK: Combine

    /// Returns a publisher that emits the local file URL when the download completes.
    func download<R: NetworkRequestable>(
        _ request: R,
        destination: URL?,
        progressHandler: (@Sendable (Double) -> Void)?
    ) -> AnyPublisher<URL, NetworkError>

    // MARK: Closure

    @discardableResult
    func download<R: NetworkRequestable>(
        _ request: R,
        destination: URL?,
        progressHandler: (@Sendable (Double) -> Void)?,
        completion: @escaping @Sendable (Result<URL, NetworkError>) -> Void
    ) -> NetworkCancellable
}
