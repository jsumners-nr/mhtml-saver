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
        /// Absolute http(s) URLs of subresources referenced by the page
        /// (images, stylesheets, fonts, CSS `url()` targets).
        let resourceURLs: [URL]
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

        // Navigation finished — pull the rendered DOM and referenced resources.
        let html = try await outerHTML(from: webView)
        let resourceURLs = await resourceURLs(from: webView)
        let title = webView.title
        let finalURL = webView.url ?? url
        self.webView = nil
        return Capture(html: html, title: title, finalURL: finalURL, resourceURLs: resourceURLs)
    }

    /// Collects absolute http(s) URLs of referenced subresources by inspecting
    /// the rendered DOM and parsed stylesheets. Runs in-page because the browser
    /// has already resolved relative URLs and `srcset` for us. Failures here are
    /// non-fatal — a page with no collectable resources simply returns [].
    private func resourceURLs(from webView: WKWebView) async -> [URL] {
        let script = """
        (function () {
          var out = new Set();
          function add(u) {
            if (!u) return;
            try {
              var abs = new URL(u, document.baseURI).href;
              if (abs.indexOf('http:') === 0 || abs.indexOf('https:') === 0) out.add(abs);
            } catch (e) {}
          }

          // <img>: use currentSrc so we embed exactly the srcset-resolved image.
          document.querySelectorAll('img').forEach(function (el) {
            add(el.currentSrc || el.src);
          });

          // <picture><source> and <video>/<audio> poster/src.
          document.querySelectorAll('source').forEach(function (el) {
            add(el.src);
            if (el.srcset) {
              el.srcset.split(',').forEach(function (part) {
                add(part.trim().split(/\\s+/)[0]);
              });
            }
          });
          document.querySelectorAll('video[poster]').forEach(function (el) { add(el.poster); });

          // Stylesheets and preloaded resources.
          document.querySelectorAll('link[rel~="stylesheet"], link[rel="preload"], link[rel="icon"], link[rel~="icon"]').forEach(function (el) {
            add(el.href);
          });

          // CSS url() references: background-image, @font-face src, etc.
          var urlRe = /url\\(\\s*['\"]?([^'\")]+)['\"]?\\s*\\)/g;
          for (var i = 0; i < document.styleSheets.length; i++) {
            var sheet = document.styleSheets[i];
            var base = sheet.href || document.baseURI;
            var rules;
            try { rules = sheet.cssRules; } catch (e) { continue; } // cross-origin
            if (!rules) continue;
            for (var j = 0; j < rules.length; j++) {
              var text = rules[j].cssText || '';
              var m;
              while ((m = urlRe.exec(text)) !== null) {
                var ref = m[1];
                if (ref.indexOf('data:') === 0) continue;
                try { add(new URL(ref, base).href); } catch (e) {}
              }
            }
          }

          return JSON.stringify(Array.from(out));
        })();
        """

        do {
            let result = try await webView.evaluateJavaScript(script)
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let strings = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return strings.compactMap { string in
                guard let url = URL(string: string),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    return nil
                }
                return url
            }
        } catch {
            // Resource extraction is best-effort; fall back to no embeds.
            return []
        }
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
