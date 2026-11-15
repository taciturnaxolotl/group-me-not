import Foundation

/// Fetches `file` attachments from GroupMe's file service, the route Android's `SaveDocumentTask` uses.
struct FileService: Sendable {
    enum Failure: Error { case unavailable, http(Int) }

    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Files", isDirectory: true)

    let tokenProvider: @Sendable () async -> String?

    /// A local copy named after the original, so Quick Look picks the right viewer; reused on later opens.
    func download(_ fileID: String, in conversationID: String, named name: String?) async throws -> URL {
        let folder = Self.directory.appendingPathComponent(fileID, isDirectory: true)
        if let cached = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first {
            return cached
        }

        guard let url = URL(string: "https://file.groupme.com/v1/\(conversationID)/files/\(fileID)")
        else { throw Failure.unavailable }
        var request = URLRequest(url: url)
        request.setValue(await tokenProvider(), forHTTPHeaderField: "X-Access-Token")

        let (file, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: file)
            throw Failure.http(http.statusCode)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(Self.safeName(name ?? response.suggestedFilename))
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.directory)
    }

    private static func safeName(_ name: String?) -> String {
        let cleaned = (name ?? "").replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "File" : cleaned
    }
}
