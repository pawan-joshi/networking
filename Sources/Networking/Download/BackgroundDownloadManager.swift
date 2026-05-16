import Foundation

// MARK: - BackgroundDownloadTask

/// Opaque handle to a background download. Store it to cancel or query progress.
public final class BackgroundDownloadTask: NSObject, Sendable {
    public let taskIdentifier: Int
    private let sessionTask: URLSessionDownloadTask

    init(sessionTask: URLSessionDownloadTask) {
        self.taskIdentifier = sessionTask.taskIdentifier
        self.sessionTask = sessionTask
    }

    public func cancel() {
        sessionTask.cancel()
    }

    public var progress: Progress {
        sessionTask.progress
    }
}

// MARK: - BackgroundDownloadManager

/// Manages file downloads that continue while the app is suspended or terminated.
///
/// ## Setup
///
/// 1. Call `BackgroundDownloadManager.shared` from anywhere in your app.
/// 2. In `AppDelegate` (or the `UIApplicationDelegate` conformance in your scene):
///    ```swift
///    func application(_ application: UIApplication,
///                     handleEventsForBackgroundURLSession identifier: String,
///                     completionHandler: @escaping () -> Void) {
///        if identifier == BackgroundDownloadManager.sessionIdentifier {
///            BackgroundDownloadManager.shared.handleEventsForBackgroundURLSession(
///                completionHandler: completionHandler
///            )
///        }
///    }
///    ```
/// 3. Optionally set `interceptors` before the first download to inject auth headers.
public final class BackgroundDownloadManager: NSObject, @unchecked Sendable {

    // MARK: - Public Constants

    public static let sessionIdentifier = "com.networklayer.background-download"

    // MARK: - Singleton

    public static let shared = BackgroundDownloadManager()

    // MARK: - Private State

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Completion handlers keyed by task identifier, guarded by `lock`.
    private var completionHandlers: [Int: @Sendable (Result<URL, NetworkError>) -> Void] = [:]
    /// Progress handlers keyed by task identifier, guarded by `lock`.
    private var progressHandlers: [Int: @Sendable (Double) -> Void] = [:]
    /// Destination URLs keyed by task identifier (nil = use system temp dir), guarded by `lock`.
    private var destinations: [Int: URL] = [:]

    private let lock = NSLock()

    /// Stored by the OS — must be called on the main thread after all background events are processed.
    private var backgroundSessionCompletionHandler: (() -> Void)?

    // MARK: - Init

    private override init() {
        super.init()
        // Touch `session` eagerly so URLSession re-connects to in-flight background tasks
        // that were started in a previous app launch.
        _ = session
    }

    // MARK: - AppDelegate Bridge

    /// Call this from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public func handleEventsForBackgroundURLSession(completionHandler: @escaping () -> Void) {
        backgroundSessionCompletionHandler = completionHandler
    }

    // MARK: - Download

    /// Schedules a background download.
    ///
    /// - Parameters:
    ///   - urlRequest: The fully formed request (headers already applied).
    ///   - destination: Where to persist the file. Pass `nil` to use a system temp path.
    ///   - progressHandler: Optional 0.0–1.0 progress callback (called on URLSession delegate queue).
    ///   - completion: Delivered on the URLSession delegate queue with the final file URL or an error.
    @discardableResult
    public func download(
        urlRequest: URLRequest,
        destination: URL? = nil,
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        completion: @escaping @Sendable (Result<URL, NetworkError>) -> Void
    ) -> BackgroundDownloadTask {
        let sessionTask = session.downloadTask(with: urlRequest)
        let handle = BackgroundDownloadTask(sessionTask: sessionTask)

        lock.withLock {
            completionHandlers[handle.taskIdentifier] = completion
            if let progressHandler { progressHandlers[handle.taskIdentifier] = progressHandler }
            if let destination    { destinations[handle.taskIdentifier] = destination }
        }

        sessionTask.resume()
        return handle
    }

    /// Cancels all in-flight background downloads.
    public func cancelAll() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloadManager: URLSessionDownloadDelegate {

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let handler = lock.withLock { progressHandlers[downloadTask.taskIdentifier] }
        handler?(fraction)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let (completion, destination) = lock.withLock {
            progressHandlers.removeValue(forKey: downloadTask.taskIdentifier)
            return (
                completionHandlers.removeValue(forKey: downloadTask.taskIdentifier),
                destinations.removeValue(forKey: downloadTask.taskIdentifier)
            )
        }

        guard let completion else { return }

        let finalURL: URL
        do {
            if let destination {
                let dir = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: location, to: destination)
                finalURL = destination
            } else {
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(location.pathExtension)
                try FileManager.default.moveItem(at: location, to: temp)
                finalURL = temp
            }
        } catch {
            completion(.failure(.unknown(error)))
            return
        }

        completion(.success(finalURL))
    }
}

// MARK: - URLSessionTaskDelegate

extension BackgroundDownloadManager: URLSessionTaskDelegate {

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }

        let completion = lock.withLock {
            progressHandlers.removeValue(forKey: task.taskIdentifier)
            destinations.removeValue(forKey: task.taskIdentifier)
            return completionHandlers.removeValue(forKey: task.taskIdentifier)
        }
        completion?(.failure(NetworkError.map(error)))
    }
}

// MARK: - URLSessionDelegate

extension BackgroundDownloadManager: URLSessionDelegate {

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundSessionCompletionHandler?()
            self?.backgroundSessionCompletionHandler = nil
        }
    }
}

// MARK: - NSLock Helper

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
