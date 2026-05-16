import Foundation
import UniformTypeIdentifiers

// MARK: - Form Data Part

/// A single field/file within a multipart body.
public struct FormDataPart: Sendable {
    public let name: String
    public let fileName: String?
    public let mimeType: String

    // Either in-memory bytes (small fields) or a file URL (large files).
    // Keeping this internal avoids exposing the distinction in the public API
    // while letting MultipartFormData choose the right encoding strategy.
    enum Source: Sendable {
        case inMemory(Data)
        case file(URL)
    }
    let source: Source

    /// Creates an in-memory part from raw bytes.
    public init(name: String, fileName: String? = nil, mimeType: String, data: Data) {
        self.name = name
        self.fileName = fileName
        self.mimeType = mimeType
        self.source = .inMemory(data)
    }

    // Internal init used by the `file` factory to avoid reading bytes up front.
    init(name: String, fileName: String?, mimeType: String, fileURL: URL) {
        self.name = name
        self.fileName = fileName
        self.mimeType = mimeType
        self.source = .file(fileURL)
    }

    // MARK: Convenience Factories

    /// Creates a file-backed part. The file is **not** read at construction time;
    /// bytes are streamed during encoding so no large allocation occurs up front.
    /// Use `MultipartFormData.encode(to:)` to keep the assembled body off the heap.
    public static func file(
        name: String,
        fileURL: URL,
        mimeType: String? = nil
    ) -> FormDataPart {
        let mime = mimeType ?? Self.mimeType(for: fileURL.pathExtension)
        return FormDataPart(name: name, fileName: fileURL.lastPathComponent, mimeType: mime, fileURL: fileURL)
    }

    /// Creates a plain-text field.
    public static func field(name: String, value: String) -> FormDataPart {
        FormDataPart(
            name: name,
            mimeType: "text/plain; charset=utf-8",
            data: Data(value.utf8)
        )
    }

    /// Creates a JSON field from any `Encodable` value.
    public static func json<T: Encodable>(
        name: String,
        value: T,
        encoder: JSONEncoder = .init()
    ) throws -> FormDataPart {
        FormDataPart(
            name: name,
            fileName: "\(name).json",
            mimeType: "application/json",
            data: try encoder.encode(value)
        )
    }

    // MARK: MIME Inference

    private static func mimeType(for pathExtension: String) -> String {
        if #available(iOS 14.0, *) {
            if let type = UTType(filenameExtension: pathExtension) {
                return type.preferredMIMEType ?? "application/octet-stream"
            }
        }
        // Fallback table for iOS 14 and common types
        switch pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "heic":        return "image/heic"
        case "pdf":         return "application/pdf"
        case "json":        return "application/json"
        case "mp4":         return "video/mp4"
        case "mov":         return "video/quicktime"
        case "mp3":         return "audio/mpeg"
        case "m4a":         return "audio/mp4"
        case "zip":         return "application/zip"
        case "txt":         return "text/plain"
        default:            return "application/octet-stream"
        }
    }
}

// MARK: - Multipart Form Data

/// Assembles multiple `FormDataPart` values into a `multipart/form-data` body.
public struct MultipartFormData: Sendable {
    public let boundary: String
    private let parts: [FormDataPart]

    public init(parts: [FormDataPart], boundary: String = "Boundary-\(UUID().uuidString)") {
        self.parts = parts
        self.boundary = boundary
    }

    /// The value for the `Content-Type` header.
    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// `true` when at least one part is backed by a file URL.
    /// `HTTPClient` uses this to pick the right upload path.
    var hasFileParts: Bool {
        parts.contains {
            if case .file = $0.source { return true }
            return false
        }
    }

    // MARK: - Encoding

    /// Serialises all parts into a single `Data` blob. Suitable for small, in-memory payloads.
    ///
    /// For payloads that contain file-backed parts (created with `FormDataPart.file(name:fileURL:)`),
    /// call `encode(to:)` instead — it writes the body to disk in chunks so the full
    /// file contents are never simultaneously resident in RAM.
    public func encode() throws -> Data {
        var body = Data()

        for part in parts {
            body.appendString("--\(boundary)\r\n")
            body.appendString(headerString(for: part))
            body.appendString("\r\n")

            switch part.source {
            case .inMemory(let data):
                body.append(data)
            case .file(let url):
                // .mappedIfSafe lets the OS page file data in on demand rather than
                // loading everything immediately, but the bytes still land in `body`
                // below. For truly large files, prefer encode(to:) instead.
                body.append(try Data(contentsOf: url, options: .mappedIfSafe))
            }

            body.appendString("\r\n")
        }

        body.appendString("--\(boundary)--\r\n")
        return body
    }

    /// Streams the multipart body to `destinationURL`, reading file-backed parts in
    /// `chunkSize`-byte chunks so the full body is never held in memory at once.
    ///
    /// The resulting file is suitable for `URLSession.upload(for:fromFile:)`, which
    /// streams it to the server without a further in-memory copy.
    public func encode(to destinationURL: URL, chunkSize: Int = 65_536) throws {
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { handle.closeFile() }

        for part in parts {
            handle.write(Data("--\(boundary)\r\n".utf8))
            handle.write(Data(headerString(for: part).utf8))
            handle.write(Data("\r\n".utf8))

            switch part.source {
            case .inMemory(let data):
                handle.write(data)
            case .file(let url):
                guard let stream = InputStream(url: url) else {
                    throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
                }
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: chunkSize)
                    guard n > 0 else { break }
                    handle.write(Data(buffer[..<n]))
                }
                if let error = stream.streamError { throw error }
            }

            handle.write(Data("\r\n".utf8))
        }

        handle.write(Data("--\(boundary)--\r\n".utf8))
    }

    // MARK: - Private Helpers

    private func headerString(for part: FormDataPart) -> String {
        var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
        if let fileName = part.fileName {
            disposition += "; filename=\"\(fileName)\""
        }
        return "\(disposition)\r\nContent-Type: \(part.mimeType)\r\n"
    }
}

// MARK: - Data Helpers

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
