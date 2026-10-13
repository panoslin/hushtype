// swift-tools-version:6.0
import PackageDescription

let vendorLib = "Vendor/SherpaOnnx/lib"

let package = Package(
    name: "Hushtype",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HushtypeCore", targets: ["HushtypeCore"]),
        .executable(name: "Hushtype", targets: ["Hushtype"]),
        .executable(name: "hushtype-cli", targets: ["hushtype-cli"]),
        .executable(name: "hushtype-engine", targets: ["hushtype-engine"]),
    ],
    dependencies: [
        // Core ML Whisper on the Apple Neural Engine. Pinned to a reviewed commit.
        .package(url: "https://github.com/argmaxinc/WhisperKit", revision: "9f99b5cb6a907730543823ad271b82532782a899"),
    ],
    targets: [
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(vendorLib)",
                    "-lsherpa-onnx-c-api",
                    "-lonnxruntime",
                    // Inside the .app the dylibs live in Contents/Frameworks.
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .target(
            name: "HushtypeCore",
            dependencies: ["CSherpaOnnx", .product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/HushtypeCore"
        ),
        .executableTarget(
            name: "Hushtype",
            dependencies: ["HushtypeCore"],
            path: "Sources/Hushtype"
        ),
        .executableTarget(
            name: "hushtype-engine",
            dependencies: ["HushtypeCore"],
            path: "Sources/hushtype-engine"
        ),
        .executableTarget(
            name: "hushtype-cli",
            dependencies: ["HushtypeCore"],
            path: "Sources/hushtype-cli",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "\(Context.packageDirectory)/\(vendorLib)"]),
            ]
        ),
        .testTarget(
            name: "HushtypeCoreTests",
            dependencies: ["HushtypeCore"],
            path: "Tests/HushtypeCoreTests",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "\(Context.packageDirectory)/\(vendorLib)"]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
