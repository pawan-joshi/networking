import Combine
import Foundation

/// Core data-transfer capability: send a typed request and receive a decoded response.
/// Split from upload/download so tests can mock only the surface they exercise.
public protocol DataTransferProtocol: AnyObject, Sendable {

    // MARK: Async / Await

    /// Sends the request and decodes the response body into `T`.
    func send<T: Decodable, R: NetworkRequestable>(_ request: R) async throws -> T

    /// Sends the request and returns the raw response bytes alongside the HTTP metadata.
    func sendRaw<R: NetworkRequestable>(_ request: R) async throws -> (data: Data, response: HTTPURLResponse)

    // MARK: Combine

    /// Returns a publisher that emits a single decoded value then completes, or fails with `NetworkError`.
    func send<T: Decodable, R: NetworkRequestable>(_ request: R) -> AnyPublisher<T, NetworkError>

    // MARK: Closure

    /// Initiates the request and delivers the result on an arbitrary background queue.
    /// Returns a `NetworkCancellable` that can be used to cancel the in-flight task.
    @discardableResult
    func send<T: Decodable, R: NetworkRequestable>(
        _ request: R,
        completion: @escaping @Sendable (Result<T, NetworkError>) -> Void
    ) -> NetworkCancellable
}
