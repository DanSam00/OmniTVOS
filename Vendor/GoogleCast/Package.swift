// swift-tools-version:5.9
// Google Cast iOS Sender SDK 4.8.6 (dynamic xcframework), unmodified, from
// https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-4.8.6_dynamic.zip
// Google ships it as CocoaPods or a zip only; this wraps the zip so the
// project can link it as a local package like the other vendored code.
import PackageDescription

let package = Package(
    name: "GoogleCast",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "GoogleCast", targets: ["GoogleCast"])
    ],
    targets: [
        .binaryTarget(name: "GoogleCast", path: "GoogleCast.xcframework")
    ]
)
