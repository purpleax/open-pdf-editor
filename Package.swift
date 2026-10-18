// swift-tools-version:6.0
import PackageDescription

// Apple Silicon only. Frameworks/MuPDF.xcframework is built by
// scripts/build-mupdf.sh (make does this first).
let package = Package(
    name: "OpenPDFEditor",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .binaryTarget(name: "MuPDF", path: "Frameworks/MuPDF.xcframework"),
        // C wrappers that catch MuPDF's setjmp/longjmp exceptions and return
        // errors as values, so Swift never sees an fz_try.
        .target(
            name: "MuPDFBridge",
            dependencies: ["MuPDF"],
            path: "Sources/MuPDFBridge",
            cSettings: [.unsafeFlags(["-Wall", "-Wno-unused-function"])],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        // Swift wrappers over the bridge, shared by the app and pdfsmoke.
        .target(
            name: "PDFCore",
            dependencies: ["MuPDFBridge"],
            path: "Sources/PDFCore"
        ),
        .executableTarget(
            name: "OpenPDFEditor",
            dependencies: ["PDFCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/OpenPDFEditor",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Command-line check that MuPDF opens and renders: pdfsmoke in.pdf out.png [page]
        .executableTarget(
            name: "pdfsmoke",
            dependencies: ["PDFCore"],
            path: "Sources/pdfsmoke"
        ),
    ]
)
