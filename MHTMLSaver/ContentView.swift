import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var urlString = ""
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle
        case working
        case success(String)
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save a web page as MHTML")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Enter a URL. The page is loaded, rendered, and saved as a single .mhtml file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("https://example.com", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .onSubmit { save() }

                Button(action: save) {
                    if status == .working {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 60)
                    } else {
                        Text("Save…")
                            .frame(width: 60)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(status == .working || normalizedURL() == nil)
            }

            statusView

            Spacer()
        }
        .padding(24)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working:
            Label("Loading and saving…", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .success(let path):
            Label("Saved to \(path)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .textSelection(.enabled)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    /// Normalizes the input into a URL, defaulting to https:// when no scheme
    /// is present. Returns nil when the input can't form a valid http(s) URL.
    private func normalizedURL() -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            candidate = "https://" + trimmed
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    private func save() {
        guard status != .working, let url = normalizedURL() else { return }
        status = .working

        Task {
            do {
                let capturer = PageCapturer()
                let capture = try await capturer.capture(url: url)
                let data = MHTMLBuilder.build(
                    html: capture.html,
                    url: capture.finalURL,
                    title: capture.title
                )

                guard let destination = await presentSavePanel(
                    suggestedName: suggestedFileName(for: capture.finalURL, title: capture.title)
                ) else {
                    status = .idle
                    return
                }

                try data.write(to: destination)
                status = .success(destination.path)
            } catch {
                status = .failure(error.localizedDescription)
            }
        }
    }

    private func suggestedFileName(for url: URL, title: String?) -> String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            let safe = title
                .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
                .joined(separator: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !safe.isEmpty { return safe + ".mhtml" }
        }
        let host = url.host ?? "page"
        return host + ".mhtml"
    }

    @MainActor
    private func presentSavePanel(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let mhtmlType = UTType(filenameExtension: "mhtml") {
            panel.allowedContentTypes = [mhtmlType]
        }
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }
}

#Preview {
    ContentView()
}
