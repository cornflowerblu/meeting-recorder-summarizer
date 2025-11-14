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
        // Firebase Auth for authentication
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "10.0.0"),
        // AWS SDK for Swift - S3, DynamoDB, and STS
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "0.40.0")
    ],
    targets: [
        .executableTarget(
            name: "MeetingRecorder",
            dependencies: [
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "AWSS3", package: "aws-sdk-swift"),
                .product(name: "AWSDynamoDB", package: "aws-sdk-swift"),
                .product(name: "AWSSTS", package: "aws-sdk-swift")
            ],
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
        ),
        .testTarget(
            name: "MeetingRecorderIntegrationTests",
            dependencies: ["MeetingRecorder"],
            path: "Tests/MeetingRecorderIntegrationTests"
        )
    ]
)
