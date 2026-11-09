import Foundation

/// Builds a minimal RFC 2557 `multipart/related` MHTML document from a
/// single rendered HTML snapshot.
///
/// This is the "Simple HTML snapshot" strategy: the rendered DOM HTML is
/// captured and wrapped as the root part of an MHTML container. Subresources
/// (images, CSS, fonts) are only embedded when they are already inline in the
/// captured HTML (e.g. data: URIs). External references are preserved as-is.
enum MHTMLBuilder {
    /// Produces the MHTML document bytes.
    ///
    /// - Parameters:
    ///   - html: The rendered DOM HTML of the page.
    ///   - url: The source URL, written to the `Content-Location` and `Snapshot-Content-Location`.
    ///   - title: Optional page title, written to the `Subject` header.
    ///   - date: Timestamp written to the `Date` header.
    static func build(
        html: String,
        url: URL,
        title: String?,
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

        var part = ""
        part += "--\(boundary)\(crlf)"
        part += "Content-Type: text/html; charset=\"utf-8\"\(crlf)"
        part += "Content-Transfer-Encoding: quoted-printable\(crlf)"
        part += "Content-Location: \(url.absoluteString)\(crlf)"
        part += crlf
        part += QuotedPrintable.encode(html)
        part += crlf

        var closing = ""
        closing += "--\(boundary)--\(crlf)"

        var data = Data()
        data.append(header.data(using: .utf8) ?? Data())
        data.append(part.data(using: .utf8) ?? Data())
        data.append(closing.data(using: .utf8) ?? Data())
        return data
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
