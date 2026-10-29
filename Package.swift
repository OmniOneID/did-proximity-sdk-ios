// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MdocProximitySDK",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MdocDevice", targets: ["MdocDevice"]),
        .library(name: "MdocReader", targets: ["MdocReader"])
    ],
    targets: [
        .target(name: "MdocProximityCore",
                path: "source/did-proximity-sdk-ios/Sources/MdocProximityCore"),

        .target(name: "MdocBLE", dependencies: ["MdocProximityCore"],
                path: "source/did-proximity-sdk-ios/Sources/Transport/MdocBLE"),
        .target(name: "MdocNFC", dependencies: ["MdocProximityCore"],
                path: "source/did-proximity-sdk-ios/Sources/Transport/MdocNFC"),

        .target(name: "MdocDevice", dependencies: ["MdocProximityCore", "MdocBLE", "MdocNFC"],
                path: "source/did-proximity-sdk-ios/Sources/Session/MdocDevice"),
        .target(name: "MdocReader", dependencies: ["MdocProximityCore", "MdocTrust", "MdocBLE", "MdocNFC"],
                path: "source/did-proximity-sdk-ios/Sources/Session/MdocReader", exclude: ["MdocTrust"]),
        .target(name: "MdocTrust", dependencies: ["MdocProximityCore"],
                path: "source/did-proximity-sdk-ios/Sources/Session/MdocReader/MdocTrust"),

        .executableTarget(name: "VectorGen", dependencies: ["MdocProximityCore"],
                          path: "source/did-proximity-sdk-ios/Sources/Tools/VectorGen"),
        .testTarget(name: "MdocProximityCoreTests",
                    dependencies: ["MdocProximityCore", "MdocTrust", "MdocDevice", "MdocReader", "MdocBLE", "MdocNFC"],
                    path: "source/did-proximity-sdk-ios/Tests/MdocProximityCoreTests")
    ]
)
