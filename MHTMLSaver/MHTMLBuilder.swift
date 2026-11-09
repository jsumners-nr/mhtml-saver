import Foundation

/// Builds an RFC 2557 `multipart/related` MHTML document: the rendered DOM HTML
/// as the root part, followed by one base64 part per embedded subresource.
///
/// Subresources are linked to the HTML by their original absolute URL via each
/// part's `Content-Location` header (the HTML's `src`/`url()` attributes are
/// left unchanged). Resources not passed in remain external references.
enum MHTMLBuilder {
    /// Produces the MHTML document bytes.
    ///
    /// - Parameters:
    ///   - html: The rendered DOM HTML of the page.
    ///   - url: The source URL, written to the HTML part's `Content-Location`.
    ///   - title: Optional page title, written to the `Subject` header.
    ///   - resources: Fetched subresources to embed as additional MIME parts.
    ///   - date: Timestamp written to the `Date` header.
    static func build(
        html: String,
        url: URL,
        title: String?,
        resources: [ResourceCollector.Resource] = [],
        date: Date = Date()
    ) -> Data {
        let boundary = "----=_MHTMLSaver_\(UUID().uuidString)"
        let crlf = "\r\n"

        var header = ""
        header += "From: <Saved by MHTMLSaver>\(crlf)"
        if let title, !title.isEmpty {
            header += "Subject: \(encodeHeaderValue(title))\(crlf)"
        }
        header += "Date: \(rfc822Date(date))\(crlf)"
        header += "MIME-Version: 1.0\(crlf)"
        header += "Content-Type: multipart/related;\(crlf)"
        header += "\ttype=\"text/html\";\(crlf)"
        header += "\tboundary=\"\(boundary)\"\(crlf)"
        header += crlf

        var data = Data()
        data.append(header.data(using: .utf8) ?? Data())

        // Root HTML part (quoted-printable).
        var htmlPart = ""
        htmlPart += "--\(boundary)\(crlf)"
        htmlPart += "Content-Type: text/html; charset=\"utf-8\"\(crlf)"
        htmlPart += "Content-Transfer-Encoding: quoted-printable\(crlf)"
        htmlPart += "Content-Location: \(url.absoluteString)\(crlf)"
        htmlPart += crlf
        htmlPart += QuotedPrintable.encode(html)
        htmlPart += crlf
        data.append(htmlPart.data(using: .utf8) ?? Data())

        // One base64 part per embedded resource.
        for resource in resources {
            var partHeader = ""
            partHeader += "--\(boundary)\(crlf)"
            partHeader += "Content-Type: \(resource.mimeType)\(crlf)"
            partHeader += "Content-Transfer-Encoding: base64\(crlf)"
            partHeader += "Content-Location: \(resource.url.absoluteString)\(crlf)"
            partHeader += crlf
            data.append(partHeader.data(using: .utf8) ?? Data())
            data.append((base64Wrapped(resource.data) + crlf).data(using: .utf8) ?? Data())
        }

        let closing = "--\(boundary)--\(crlf)"
        data.append(closing.data(using: .utf8) ?? Data())
        return data
    }

    /// Base64-encodes `data` wrapped to 76-character lines with CRLF endings,
    /// as expected for a MIME `base64` transfer encoding.
    private static func base64Wrapped(_ data: Data) -> String {
        data.base64EncodedString(options: [
            .lineLength76Characters,
            .endLineWithCarriageReturn,
            .endLineWithLineFeed,
        ])
    }

    /// RFC 822 date, e.g. `Mon, 09 Nov 2026 13:15:00 +0000`.
    private static func rfc822Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// Encodes a header value as RFC 2047 encoded-word when it contains
    /// non-ASCII characters, so titles with Unicode survive intact.
    private static func encodeHeaderValue(_ value: String) -> String {
        if value.allSatisfy({ $0.isASCII }) {
            return value
        }
        let base64 = Data(value.utf8).base64EncodedString()
        return "=?utf-8?B?\(base64)?="
    }
}

/// Minimal quoted-printable encoder (RFC 2045) suitable for MHTML text parts.
enum QuotedPrintable {
    static func encode(_ string: String) -> String {
        let bytes = Array(string.utf8)
        var output = ""
        var lineLength = 0

        func appendToken(_ token: String) {
            // Soft line break to keep lines <= 76 chars per RFC 2045.
            if lineLength + token.count > 75 {
                output += "=\r\n"
                lineLength = 0
            }
            output += token
            lineLength += token.count
        }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]

            if byte == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                output += "\r\n"
                lineLength = 0
                index += 2
                continue
            }
            if byte == 0x0A {
                output += "\r\n"
                lineLength = 0
                index += 1
                continue
            }

            // Printable ASCII (excluding '=') passes through; everything else
            // is escaped as =XX.
            if (byte >= 0x21 && byte <= 0x7E && byte != 0x3D) || byte == 0x20 || byte == 0x09 {
                appendToken(String(UnicodeScalar(byte)))
            } else {
                appendToken(String(format: "=%02X", byte))
            }
            index += 1
        }

        return output
    }
}
