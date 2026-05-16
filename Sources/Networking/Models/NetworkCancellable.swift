import Foundation

/// A handle that can cancel an in-flight network operation.
/// Analogous to `AnyCancellable` from Combine but available without importing Combine.
public protocol NetworkCancellable: Sendable {
    func cancel()
}

// MARK: - Task-backed Implementation

/// Wraps a Swift `Task` so closure-based APIs can return a cancellable token.
public struct TaskCancellable: NetworkCancellable {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    public func cancel() {
        task.cancel()
    }
}

// MARK: - No-op (useful as a test stub)

public struct VoidCancellable: NetworkCancellable {
    public init() {}
    public func cancel() {}
}
