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
  navigation to finish, and reads the rendered DOM via
  `document.documentElement.outerHTML`.
- `MHTMLBuilder` wraps that HTML as the root part of an RFC 2557
  `multipart/related` document with a `text/html` part encoded as
  quoted-printable.

This is the **simple HTML snapshot** strategy: the fully rendered DOM is
captured (so JavaScript-generated content is included), but external
subresources (images, stylesheets, fonts) are embedded only when they are
already inline in the page (e.g. `data:` URIs). External URLs are preserved
as references. The resulting `.mhtml` opens in Chrome, Edge, and other
browsers that support MHTML.

## Requirements

- macOS 14.0+
- **Full Xcode** to build. (Bare Command Line Tools cannot compile the
  `#Preview` macro or drive `.xcodeproj` files via `xcodebuild`.)

## Project layout

```
MHTMLSaver/
  MHTMLSaverApp.swift   App entry point
  ContentView.swift     URL input, validation, save flow (NSSavePanel)
  PageCapturer.swift     WKWebView loader + DOM extraction
  MHTMLBuilder.swift     RFC 2557 MHTML assembly + quoted-printable encoder
  Info.plist
  MHTMLSaver.entitlements  App Sandbox: network client + user-selected files
```
