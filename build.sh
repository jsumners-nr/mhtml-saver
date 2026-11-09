#!/bin/bash
#
# Builds MHTMLSaver.app without Xcode, using only the Command Line Tools
# (swiftc + codesign). Produces an ad-hoc-signed, sandboxed .app you can run
# locally.
#
# Usage:
#   ./build.sh            # build into ./build/MHTMLSaver.app
#   ./build.sh --run      # build, then launch the app
#   ./build.sh --clean    # remove the build directory and exit
#
# Notes:
#   - The #Preview block in ContentView.swift is stripped from a *copy* only;
#     your source files are never modified. (#Preview needs an Xcode-only macro
#     plugin and won't compile under bare Command Line Tools.)
#   - Ad-hoc signing is fine for running on this machine. Distributing to other
#     Macs needs a Developer ID certificate + notarization.

set -euo pipefail

# Resolve paths relative to this script so it works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/MHTMLSaver"
BUILD_DIR="$SCRIPT_DIR/build"
STAGE_DIR="$BUILD_DIR/stage"
APP="$BUILD_DIR/MHTMLSaver.app"
ENTITLEMENTS="$SRC_DIR/MHTMLSaver.entitlements"

# Project settings (kept in sync with project.pbxproj).
BUNDLE_ID="com.example.MHTMLSaver"
PRODUCT_NAME="MHTMLSaver"
DISPLAY_NAME="MHTML Saver"
MARKETING_VERSION="1.0"
BUILD_VERSION="1"
DEPLOYMENT_TARGET="14.0"

RUN_AFTER=0
for arg in "$@"; do
	case "$arg" in
		--run)   RUN_AFTER=1 ;;
		--clean) rm -rf "$BUILD_DIR"; echo "Removed $BUILD_DIR"; exit 0 ;;
		-h|--help)
			sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*) echo "Unknown option: $arg" >&2; exit 2 ;;
	esac
done

# Preflight: confirm the toolchain is available.
if ! command -v xcrun >/dev/null 2>&1; then
	echo "error: xcrun not found. Install the Command Line Tools: xcode-select --install" >&2
	exit 1
fi

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx${DEPLOYMENT_TARGET}"

echo "==> SDK:    $SDK_PATH"
echo "==> Target: $TARGET"

# Fresh staging area.
rm -rf "$BUILD_DIR"
mkdir -p "$STAGE_DIR"

# Stage sources, stripping the trailing #Preview block from ContentView only.
# The awk program copies lines until it sees a line beginning with "#Preview",
# then stops — the preview macro is always the last declaration in the file.
for f in "$SRC_DIR"/*.swift; do
	base="$(basename "$f")"
	if [ "$base" = "ContentView.swift" ]; then
		awk '/^#Preview/{exit} {print}' "$f" > "$STAGE_DIR/$base"
	else
		cp "$f" "$STAGE_DIR/$base"
	fi
done

# Compile all Swift sources into a single optimized executable.
echo "==> Compiling..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc \
	-sdk "$SDK_PATH" \
	-target "$TARGET" \
	-parse-as-library \
	-O \
	"$STAGE_DIR"/*.swift \
	-o "$APP/Contents/MacOS/$PRODUCT_NAME"

# Write the bundle Info.plist.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>${PRODUCT_NAME}</string>
	<key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
	<key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
	<key>CFBundleExecutable</key><string>${PRODUCT_NAME}</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSMinimumSystemVersion</key><string>${DEPLOYMENT_TARGET}</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc sign with the sandbox entitlements.
echo "==> Signing (ad-hoc)..."
codesign --force --sign - --entitlements "$ENTITLEMENTS" --options runtime "$APP"
codesign --verify --verbose "$APP"

echo "==> Built: $APP"

if [ "$RUN_AFTER" -eq 1 ]; then
	echo "==> Launching..."
	open "$APP"
fi
