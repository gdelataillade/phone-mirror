import Foundation
// swift-tools-version: 6.2
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
  name: "iPhoneMirror",
  platforms: [.macOS("27.0")],
  products: [.executable(name: "iPhoneMirror", targets: ["iPhoneMirror"])],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
  ],
  targets: [
    .systemLibrary(name: "CMirror", path: "Sources/CMirror"),
    .target(name: "MirrorCore"),
    .executableTarget(
      name: "iPhoneMirror", dependencies: ["CMirror", "MirrorCore", "Sparkle"],
      linkerSettings: [
        .unsafeFlags(["-L", root + "/Backend/target/release"]),
        .linkedLibrary("phone_mirror_backend"),
        .linkedFramework("Security"), .linkedFramework("SystemConfiguration"),
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
      ]),
    .testTarget(name: "MirrorCoreTests", dependencies: ["MirrorCore"]),
  ],
  swiftLanguageModes: [.v5]
)
