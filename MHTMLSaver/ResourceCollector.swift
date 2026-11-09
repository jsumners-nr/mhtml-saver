import Foundation

/// Fetches page subresources so they can be embedded in an MHTML document.
///
/// Collection is best-effort and bounded: each fetch has its own timeout,
/// fetches run with limited concurrency, and any resource that fails (network
/// error, non-2xx, empty body) is simply skipped — the page's external
/// reference to it stays intact in the saved file.
enum ResourceCollector {
    struct Resource {
        let url: URL
        let mimeType: String
        let data: Data
    }

    /// Summary of a collection pass, so callers can report what was embedded.
    struct Result {
        let resources: [Resource]
        /// Total distinct URLs attempted.
        let attempted: Int
    }

    /// Fetches `urls` and returns the successfully retrieved resources.
    ///
    /// - Parameters:
    ///   - urls: Absolute http(s) resource URLs (duplicates are coalesced).
    ///   - perResourceTimeout: Per-request timeout in seconds.
    ///   - maxConcurrent: Maximum simultaneous fetches.
    static func collect(
        urls: [URL],
        perResourceTimeout: TimeInterval = 15,
        maxConcurrent: Int = 6
    ) async -> Result {
        // Dedupe by absolute string, preserving first-seen order.
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0.absoluteString).inserted }

        guard !unique.isEmpty else {
            return Result(resources: [], attempted: 0)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = perResourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let cap = max(1, maxConcurrent)

        let resources = await withTaskGroup(of: Resource?.self) { group -> [Resource] in
            var collected: [Resource] = []
            var index = 0

            // Prime the group up to the concurrency cap.
            while index < unique.count, index < cap {
                let url = unique[index]
                group.addTask { await fetch(url, session: session) }
                index += 1
            }

            // As each finishes, enqueue the next to keep `cap` in flight.
            while let result = await group.next() {
                if let result { collected.append(result) }
                if index < unique.count {
                    let url = unique[index]
                    group.addTask { await fetch(url, session: session) }
                    index += 1
                }
            }

            return collected
        }

        return Result(resources: resources, attempted: unique.count)
    }

    /// Fetches a single resource; returns nil on any failure.
    private static func fetch(_ url: URL, session: URLSession) async -> Resource? {
        do {
            let (data, response) = try await session.data(from: url)
            guard !data.isEmpty else { return nil }
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                return nil
            }
            let mimeType = response.mimeType ?? mimeType(forExtension: url.pathExtension)
            return Resource(url: url, mimeType: mimeType, data: data)
        } catch {
            return nil
        }
    }

    /// Best-guess MIME type from a file extension, used when the server omits
    /// a usable `Content-Type`.
    private static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "bmp": return "image/bmp"
        case "avif": return "image/avif"
        case "css": return "text/css"
        case "js", "mjs": return "application/javascript"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "eot": return "application/vnd.ms-fontobject"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }
}
