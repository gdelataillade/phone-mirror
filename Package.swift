import Foundation
// swift-tools-version: 6.2
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
  name: "PhoneMirror",
  platforms: [.macOS("27.0")],
  products: [.executable(name: "PhoneMirror", targets: ["PhoneMirror"])],
  targets: [
    .systemLibrary(name: "CMirror", path: "Sources/CMirror"),
    .target(name: "MirrorCore"),
    .executableTarget(
      name: "PhoneMirror", dependencies: ["CMirror", "MirrorCore"],
      linkerSettings: [
        .unsafeFlags(["-L", root + "/Backend/target/release"]),
        .linkedLibrary("phone_mirror_backend"),
        .linkedFramework("Security"), .linkedFramework("SystemConfiguration"),
      ]),
    .testTarget(name: "MirrorCoreTests", dependencies: ["MirrorCore"]),
  ],
  swiftLanguageModes: [.v5]
)
