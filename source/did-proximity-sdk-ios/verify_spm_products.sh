#!/bin/bash
# Uses the compiler to check what SPM consumers actually get (the SPM counterpart of `verify_xcframework.sh`).
#
# **Adding the one product for a role must bring the shared modules along, with a single `import`.**
# Only the `@_exported` in the two session files holds that promise up, and if it is removed
# both `swift test` and `verify_xcframework.sh` still pass — **only apps break, silently.**
# This script closes that gap.
#
# Checks two things.
#   1. A single `import MdocReader` exposes the Core and Trust types
#   2. A single `import MdocDevice` exposes the Core types
set -e

REPO="$(cd "$(dirname "$0")/../.." && pwd)"   # repository root, where Package.swift is
PKG="did-proximity-sdk-ios"               # package identity of the path dependency = folder name
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/Sources/ReaderApp" "$TMP/Sources/DeviceApp"

cat > "$TMP/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConsumerCheck",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [.package(path: "$REPO")],
    targets: [
        .target(name: "ReaderApp",
                dependencies: [.product(name: "MdocReader", package: "$PKG")]),
        .target(name: "DeviceApp",
                dependencies: [.product(name: "MdocDevice", package: "$PKG")])
    ]
)
EOF

# ── Reader app — one import reaches Core and Trust ──────────────────────────────────
cat > "$TMP/Sources/ReaderApp/ReaderApp.swift" <<'SWIFT'
import Foundation
import MdocReader          // this one line must be all it takes

func readerApp(trust: TrustEvaluatorProtocol) async throws {
    var configuration = MdocReaderConfiguration()          // Core
    configuration.skipIssuerAuth = false
    configuration.transmissionPriority = [.ble, .nfc]                   // Core (kinds only)
    configuration.blePreferredMode = .central                            // Core

    let session = MdocReaderSession(configuration: configuration, trust: trust)  // MdocReader
    try await session.connect(to: try EngagementPayload.parse(qrString: "mdoc:oA"))  // Core
    let response = try await session.request([ItemsRequestPresets.identity], at: Date())  // Core

    for doc in response.documents {                        // MdocReader
        _ = (doc.verdict, doc.warnings, doc.digests?.allMatch, doc.issuerDataAuth.trust)
        _ = doc.issuerSignedElements[MdocDocTypes.mDLNameSpace]?["family_name"]?.asText  // Core
    }
    _ = MdocCapabilities.current().mdocReader.ble          // Core
}

// Trust lives in MdocTrust — without the re-export this breaks here
func makeTrust() -> TrustEvaluatorProtocol {
    DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() }
}
SWIFT

# ── mdoc app — one import reaches Core ───────────────────────────────────────
cat > "$TMP/Sources/DeviceApp/DeviceApp.swift" <<'SWIFT'
import Foundation
import MdocDevice          // this one line must be all it takes

func deviceApp(delegate: MdocDeviceSessionDelegate) async throws {
    var configuration = MdocDeviceConfiguration()          // Core
    configuration.bleAdvertiseMode = .both                 // Core

    let session = MdocDeviceSession(configuration: configuration)   // MdocDevice
    session.delegate = delegate
    let payload = try await session.start(technology: .qr)          // Core(EngagementTechnology)
    _ = payload.qrString                                            // Core
    try await session.respond(deviceResponse: Data())
    session.terminate()
    _ = MdocCapabilities.current().mdoc.ble                         // Core
}
SWIFT

echo "1) Does a single import MdocReader expose Core and Trust?"
echo "2) Does a single import MdocDevice expose Core?"
if swift build --package-path "$TMP" 2>&1 | tee "$TMP/build.log" | grep -q "error:"; then
  echo "   FAIL — see the error below. The role module's @_exported is most likely missing"
  grep "error:" "$TMP/build.log" | head -10
  exit 1
fi
echo "   PASS"
echo "SPM product consumption check passed"
