import Foundation

/// Abstracts the decoding step so tests can inject fakes without touching URLSession.
public protocol ResponseDecoderProtocol: Sendable {
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

// MARK: - JSONDecoder Conformance

extension JSONDecoder: ResponseDecoderProtocol {}
