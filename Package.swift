// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ThisIsLogged",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "ThisIsLoggedCore", targets: ["ThisIsLoggedCore"]),
    .executable(name: "ThisIsLogged", targets: ["ThisIsLogged"]),
    .executable(name: "ThisIsLoggedSelfcheck", targets: ["ThisIsLoggedSelfcheck"]),
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2"),
  ],
  targets: [
    .target(name: "ThisIsLoggedCore", linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("EventKit")]),
    .executableTarget(
      name: "ThisIsLogged",
      dependencies: ["ThisIsLoggedCore", .product(name: "Sparkle", package: "Sparkle")],
      path: "macos",
      exclude: ["AppIcon.icns", "AppIcon.png", "Info.plist"],
      sources: ["main.swift", "SyncWindowController.swift", "ClaudeActivityWindowController.swift"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("UserNotifications"),
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
      ]
    ),
    .executableTarget(name: "ThisIsLoggedSelfcheck", dependencies: ["ThisIsLoggedCore"]),
  ]
)
