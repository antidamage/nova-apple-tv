// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NovaSRT",
    platforms: [.tvOS(.v15)],
    products: [
        .library(name: "NovaSRT", targets: ["NovaSRT"]),
    ],
    targets: [
        .binaryTarget(
            name: "libsrt",
            url: "https://github.com/HaishinKit/libsrt-xcframework/releases/download/v1.5.4/libsrt.xcframework.zip",
            checksum: "76879e2802e45ce043f52871a0a6764d57f833bdb729f2ba6663f4e31d658c4a"
        ),
        .target(
            name: "NovaSRT",
            dependencies: ["libsrt"],
            path: "Sources/NovaSRT",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("c++")]
        ),
    ]
)
