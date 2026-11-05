// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypelessMLX",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(name: "TypelessMLXTextSupport", path: "TypelessMLX/TextSupport"),
        .executableTarget(name: "TypelessMLXGainAndTextTests", dependencies: ["TypelessMLXAudioTapSupport", "TypelessMLXTextSupport"], path: "TypelessMLX/Tests/GainAndText"),
        .target(name: "TypelessMLXWorkflowSupport", path: "TypelessMLX/WorkflowSupport"),
        .executableTarget(name: "TypelessMLXWorkflowTests", dependencies: ["TypelessMLXWorkflowSupport"], path: "TypelessMLX/Tests/Workflow"),
        .target(
            name: "TypelessMLXHotkeySupport",
            path: "TypelessMLX/HotkeySupport"
        ),
        .target(
            name: "TypelessMLXAudioTapSupport",
            path: "TypelessMLX/AudioSupport",
            linkerSettings: [
                .linkedFramework("AVFoundation")
            ]
        ),
        .target(
            name: "TypelessMLXAudioInputSupport",
            path: "TypelessMLX/AudioInputSupport"
        ),
        .executableTarget(
            name: "TypelessMLX",
            dependencies: [
                "TypelessMLXHotkeySupport",
                "TypelessMLXAudioTapSupport",
                "TypelessMLXAudioInputSupport",
                "TypelessMLXSpeechBackendPolicy",
                "TypelessMLXWorkflowSupport",
                "TypelessMLXTextSupport"
            ],
            path: "TypelessMLX/Sources",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])
            ]
        ),
        .executableTarget(
            name: "TypelessMLXAudioTapFormatTests",
            dependencies: ["TypelessMLXAudioTapSupport"],
            path: "TypelessMLX/Tests/AudioTapFormat"
        ),
        .executableTarget(
            name: "TypelessMLXAudioInputAvailabilityTests",
            dependencies: ["TypelessMLXAudioInputSupport"],
            path: "TypelessMLX/Tests/AudioInputAvailability"
        ),
        .executableTarget(
            name: "TypelessMLXHotkeySupportTests",
            dependencies: ["TypelessMLXHotkeySupport"],
            path: "TypelessMLX/Tests/HotkeySupport"
        ),
        .target(
            name: "TypelessMLXSpeechBackendPolicy",
            path: "TypelessMLX/SpeechBackendPolicy"
        ),
        .executableTarget(
            name: "TypelessMLXSpeechBackendPolicyTests",
            dependencies: ["TypelessMLXSpeechBackendPolicy"],
            path: "TypelessMLX/Tests/SpeechBackendPolicy"
        )
    ]
)
