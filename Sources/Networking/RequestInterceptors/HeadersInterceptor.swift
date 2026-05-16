import Foundation

public struct HeadersInterceptor: RequestInterceptorProtocol {
    private let headers: @Sendable () async throws -> [String: String]

    public init(headers: @escaping @Sendable () async throws -> [String: String]) {
        self.headers = headers
    }

    public func adapt(_ request: URLRequest) async throws -> URLRequest {
        var modified = request
        
        try await headers().forEach { key, value in
            if modified.allHTTPHeaderFields?[key] == nil {
                modified.setValue(value, forHTTPHeaderField: key)
            }
        }
        return modified
    }
}
