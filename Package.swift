// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Island",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "Island",
            path: "Sources/Island",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("EventKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
            ]
        ),
    ]
)
