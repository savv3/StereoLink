// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StereoLink",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "StereoLink",
            path: "Sources/StereoLink",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
