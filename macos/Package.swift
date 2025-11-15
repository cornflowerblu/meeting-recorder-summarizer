// swift-tools-version: 6.0
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
    // AWS SDK for Swift - S3, DynamoDB, STS
    .package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "1.0.0"),

    // Firebase - Authentication (version matches project.yml)
    .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "10.20.0"),
  ],
  targets: [
    .executableTarget(
      name: "MeetingRecorder",
      dependencies: [
        .product(name: "AWSS3", package: "aws-sdk-swift"),
        .product(name: "AWSDynamoDB", package: "aws-sdk-swift"),
        .product(name: "AWSSTS", package: "aws-sdk-swift"),
        .product(name: "AWSClientRuntime", package: "aws-sdk-swift"),
        .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
      ],
      path: "Sources/MeetingRecorder",
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
        .enableUpcomingFeature("BareSlashRegexLiterals"),
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
  ]
)
