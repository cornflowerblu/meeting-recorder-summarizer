// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "MeetingRecorder",
            targets: ["MeetingRecorder"]
        )
    ],
    dependencies: [
        // Dependencies will be added in Phase 2 (Foundational):
        // - Firebase Auth for authentication
        // - AWS SDK for S3, DynamoDB, and STS
    ],
    targets: [
        .executableTarget(
            name: "MeetingRecorder",
            dependencies: [],
            path: "Sources/MeetingRecorder",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "MeetingRecorderTests",
            dependencies: ["MeetingRecorder"],
            path: "Tests/MeetingRecorderTests"
        ),
        .testTarget(
            name: "MeetingRecorderUITests",
            dependencies: ["MeetingRecorder"],
            path: "Tests/MeetingRecorderUITests"
        )
    ]
)
