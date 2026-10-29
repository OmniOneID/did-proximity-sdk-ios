#!/bin/bash
# Checks that the distributed artifact can actually be consumed. **Linking the framework target and
# linking the XCFramework are different things** — the latter reads the `.swiftinterface`, so
# broken library evolution shows up only here.
#
# Checks two things.
#   1. Code that uses **only the public API** via `import MdocProximitySDK` compiles
#   2. The SPI is not visible through a plain import, only through `@_spi(MdocInternal) import`
set -e

VERSION="${1:-1.0.0}"
XC="../release/did-proximity-sdk-ios-${VERSION}/MdocProximitySDK.xcframework/ios-arm64"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -d "$XC" ] || { echo "Run ./build_xcframework.sh first: $XC not found"; exit 1; }

cat > "$TMP/public_only.swift" <<'SWIFT'
import Foundation
import MdocProximitySDK

// The surface apps use
func app(trust: TrustEvaluatorProtocol) async throws {
    let reader = MdocReaderSession(configuration: MdocReaderConfiguration(), trust: trust)
    let engagement = try EngagementPayload.parse(qrString: "mdoc:oA")
    try await reader.connect(to: engagement)
    let response = try await reader.request([ItemsRequestPresets.identity], at: Date())
    // The whole verification result model must be visible
    for doc in response.documents {
        _ = (doc.verdict, doc.warnings, doc.retainable, doc.digests?.allMatch,
             doc.issuerDataAuth.trust, doc.issuerDataAuth.verificationSkipped,
             doc.deviceSignedElements, doc.allElements,
             doc.provenance(MdocDocTypes.mDLNameSpace, "portrait"))
        for w in doc.warnings { if case .unrequestedElement = w { _ = doc.retainableElements() } }
    }
    reader.terminate()

    // The only thing the app picks is the BLE mode
    var configuration = MdocDeviceConfiguration()
    configuration.bleAdvertiseMode = .centralClient
    configuration.callbackQueue = DispatchQueue(label: "app")      // callback queue
    let mdoc = MdocDeviceSession(configuration: configuration)
    _ = try await mdoc.start(technology: .qr)
    mdoc.terminate()
}
SWIFT

cat > "$TMP/spi_needs_import.swift" <<'SWIFT'
import MdocProximitySDK
// The transport layer must not be visible through this import
func leak() { _ = LoopbackTransport.self }
SWIFT

cat > "$TMP/spi_ok.swift" <<'SWIFT'
@_spi(MdocInternal) import MdocProximitySDK
func internalOnly() { _ = LoopbackTransport.pair() }
SWIFT

compile() {
  xcrun swiftc -typecheck -target arm64-apple-ios17.0 -sdk "$SDK" -F "$XC" "$1" 2>&1
}

echo "1) Does it compile with the public API only?"
if compile "$TMP/public_only.swift"; then echo "   PASS"; else echo "   FAIL"; exit 1; fi

echo "2) Does the SPI stay hidden from a plain import?"
if compile "$TMP/spi_needs_import.swift" > "$TMP/leak.log"; then
  echo "   FAIL — the transport layer is visible to the app"; exit 1
else
  grep -q "cannot find 'LoopbackTransport'" "$TMP/leak.log" \
    && echo "   PASS (not visible)" \
    || { echo "   FAIL — unexpected error:"; cat "$TMP/leak.log"; exit 1; }
fi

echo "3) Is it visible through the SPI import?"
if compile "$TMP/spi_ok.swift"; then echo "   PASS"; else echo "   FAIL"; exit 1; fi
echo "XCFramework consumption check passed"
