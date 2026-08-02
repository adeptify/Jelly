// swift-tools-version: 6.3
import PackageDescription

let commandLineToolsTestingLibraryPath =
    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let testingLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L", commandLineToolsTestingLibraryPath,
        "-Xlinker", "-rpath",
        "-Xlinker", commandLineToolsTestingLibraryPath
    ], .when(platforms: [.macOS]))
]

let package = Package(
    name: "PersonalCalendar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CalendarDomain", targets: ["CalendarDomain"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "70eff261d7f462cad1fff51e05bcc74aa0b0f420"
        )
    ],
    targets: [
        .target(name: "CalendarDomain"),
        .testTarget(
            name: "CalendarDomainTests",
            dependencies: [
                "CalendarDomain",
                .product(name: "Testing", package: "swift-testing")
            ],
            linkerSettings: testingLinkerSettings
        )
    ]
)
