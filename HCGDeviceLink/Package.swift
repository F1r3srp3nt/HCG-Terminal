// swift-tools-version:5.7
// HCG Device Link client (hcg.devicelink/1) for HCG Sentinel, HCG Terminal
// and HCG Nexus. The source of truth lives in HCG-Server
// (clients/swift/HCGDeviceLink); apps vendor an identical copy
// (see VENDORING.md). Apple platforms use CryptoKit and Security only;
// swift-crypto is used solely to build and test on Linux.
import PackageDescription

var dependencies: [Package.Dependency] = []
var cryptoDependency: [Target.Dependency] = []
#if os(Linux)
dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "4.0.0"))
cryptoDependency.append(.product(name: "Crypto", package: "swift-crypto"))
#endif

let package = Package(
    name: "HCGDeviceLink",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [
        .library(name: "HCGDeviceLink", targets: ["HCGDeviceLink"]),
    ],
    dependencies: dependencies,
    targets: [
        .target(name: "HCGDeviceLink", dependencies: cryptoDependency),
        .testTarget(name: "HCGDeviceLinkTests", dependencies: ["HCGDeviceLink"], resources: [.copy("Vectors")]),
    ]
)
