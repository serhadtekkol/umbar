// swift-tools-version: 6.1
// Vendored from TheBoredTeam/MacroVisionKit 0.2.0; see VENDORED.txt.
// The upstream example executable target is not vendored.
import PackageDescription

let package = Package(
    name: "MacroVisionKit",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "MacroVisionKit",
            targets: ["MacroVisionKit"]),
    ],
    targets: [
        .target(
            name: "MacroVisionKit"),
    ]
)
