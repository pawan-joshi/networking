import Foundation

/// A bearer access token persisted between launches.
///
/// `Token` is the unit of work passed between `TokenStorage` (where the value
/// lives) and `TokenProvider` (which vends it to the network layer).
public struct Token: Sendable, Equatable, Hashable, Codable {
    public let accessToken: String

    public init(accessToken: String) {
        self.accessToken = accessToken
    }
}
