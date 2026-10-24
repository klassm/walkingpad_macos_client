// swift-tools-version:5.9
// Test harness for the walkingpad-client Swift sources.
// The app is built by walkingpad-client.xcodeproj; this package exists so the
// service code can be exercised with `swift test` (no external dependencies).
import PackageDescription

let package = Package(
    name: "walkingpad-client-tests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "walkingpad-client",
            path: "walkingpad-client",
            exclude: [
                "Info.plist",
                "services/MqttService.swift",          // depends on MQTTNIO
                "walkingpad_clientApp.swift",          // @main entry point
                "walkingpad_client.entitlements",
                "Assets.xcassets",
                "Preview Content",
            ]
        ),
        .testTarget(
            name: "walkingpad-client-tests",
            dependencies: ["walkingpad-client"],
            path: "Tests/walkingpad-client-tests"
        ),
    ]
)
