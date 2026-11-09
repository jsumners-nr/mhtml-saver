import Foundation
import WebKit

/// Loads a URL in an off-screen `WKWebView` and captures the rendered DOM HTML
/// along with the page title.
@MainActor
final class PageCapturer: NSObject, WKNavigationDelegate {
    struct Capture {
        let html: String
        let title: String?
        let finalURL: URL
    }

    enum CaptureError: LocalizedError {
        case navigationFailed(String)
        case domExtractionFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .navigationFailed(let message):
                return "Failed to load the page: \(message)"
            case .domExtractionFailed(let message):
                return "Failed to read the page content: \(message)"
            case .timedOut:
                return "Timed out while loading the page."
            }
        }
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    /// Loads `url` and returns the captured snapshot.
    func capture(url: URL, timeout: TimeInterval = 30) async throws -> Capture {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(CaptureError.timedOut))
            }
            webView.load(URLRequest(url: url))
        }

        // Navigation finished — pull the rendered DOM.
        let html = try await outerHTML(from: webView)
        let title = webView.title
        let finalURL = webView.url ?? url
        self.webView = nil
        return Capture(html: html, title: title, finalURL: finalURL)
    }

    private func outerHTML(from webView: WKWebView) async throws -> String {
        let script = "document.documentElement.outerHTML"
        do {
            let result = try await webView.evaluateJavaScript(script)
            guard let html = result as? String else {
                throw CaptureError.domExtractionFailed("Unexpected result type.")
            }
            // Prepend the doctype which outerHTML omits.
            return "<!DOCTYPE html>\n" + html
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.domExtractionFailed(error.localizedDescription)
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(CaptureError.navigationFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(CaptureError.navigationFailed(error.localizedDescription)))
    }
}
