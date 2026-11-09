# MHTML Saver

A small macOS SwiftUI app that takes a URL, loads and renders the page, and
saves it as a single `.mhtml` file.

## Usage

### Option A — Xcode

1. Open `MHTMLSaver.xcodeproj` in Xcode.
2. Build and run (the scheme `MHTMLSaver` is already shared).

### Option B — No Xcode (`build.sh`)

Builds with just the Command Line Tools (`swiftc` + `codesign`):

```sh
./build.sh          # build build/MHTMLSaver.app
./build.sh --run    # build, then launch
./build.sh --clean  # remove the build/ directory
```

The resulting app is ad-hoc signed (fine for running locally; distribution to
other Macs needs a Developer ID certificate + notarization). `build.sh` strips
the `#Preview` block from a *copy* of `ContentView.swift` — your sources are
never modified — because that macro requires an Xcode-only plugin.

### Then

1. Type a URL (e.g. `example.com` — `https://` is assumed if you omit the scheme).
2. Click **Save…**, choose a destination, and the page is written as `.mhtml`.

## How it works

- `PageCapturer` loads the URL in an off-screen `WKWebView`, waits for
  navigation to finish, reads the rendered DOM via
  `document.documentElement.outerHTML`, and runs a second script to collect the
  absolute URLs of referenced subresources (images via `currentSrc`, `<picture>`
  sources, stylesheets, preloads, and CSS `url()` targets such as
  background-images and `@font-face` fonts).
- `ResourceCollector` fetches those URLs over `URLSession` with bounded
  concurrency and a per-resource timeout. Failed or slow resources are skipped
  (they stay as external references); `data:` URIs are left inline.
- `MHTMLBuilder` writes an RFC 2557 `multipart/related` document: the rendered
  DOM as a quoted-printable `text/html` root part, followed by one base64 part
  per fetched resource, each linked by its original absolute URL via
  `Content-Location`.

This produces a self-contained, Chrome/Edge-style `.mhtml` that renders offline:
images, stylesheets, and fonts are embedded as separate MIME parts. The HTML's
`src`/`url()` attributes are left unchanged — the MIME `Content-Location` is
what links them to the embedded parts. The save status reports how many
resources were embedded (and how many, if any, were skipped).

## Requirements

- macOS 14.0+
- **Full Xcode** to build. (Bare Command Line Tools cannot compile the
  `#Preview` macro or drive `.xcodeproj` files via `xcodebuild`.)

## Project layout

```
MHTMLSaver/
  MHTMLSaverApp.swift   App entry point
  ContentView.swift     URL input, validation, save flow (NSSavePanel)
  PageCapturer.swift     WKWebView loader + DOM/resource-URL extraction
  ResourceCollector.swift  Concurrent URLSession fetch of subresources
  MHTMLBuilder.swift     RFC 2557 MHTML assembly (QP html + base64 parts)
  Info.plist
  MHTMLSaver.entitlements  App Sandbox: network client + user-selected files
```
