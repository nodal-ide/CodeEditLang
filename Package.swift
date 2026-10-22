// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CodeEditLang",
    platforms: [.macOS(.v13)],
    products: [
        // Language-agnostic bridge: models, symbol index, native-language SPI.
        .library(name: "CodeEditLang", targets: ["CodeEditLang"]),
        // First native language implementation: PHP.
        .library(name: "CodeEditLangPHP", targets: ["CodeEditLangPHP"]),
    ],
    dependencies: [
        // The editor core the providers plug into (delegates, text controller).
        .package(
            url: "https://github.com/nodal-ide/CodeEditSourceEditor.git",
            revision: "d67543ba928cf7f845f2edf3f57e60c732151025"
        ),
        // The text view (CursorPosition, TextView insertion API).
        .package(
            url: "https://github.com/nodal-ide/CodeEditTextView.git",
            revision: "eb9820c2384ce5f6661d29846a147390f6ff538e"
        ),
        // Tree-sitter grammars + CodeLanguage definitions.
        .package(
            url: "https://github.com/nodal-ide/CodeEditLanguages.git",
            revision: "497fc6a7c5c0042bf3c0d2b907be6b145a963364"
        ),
    ],
    targets: [
        .target(
            name: "CodeEditLang"
        ),
        .target(
            name: "CodeEditLangPHP",
            dependencies: [
                "CodeEditLang",
                "CodeEditSourceEditor",
                "CodeEditTextView",
                "CodeEditLanguages",
            ],
            resources: [
                .copy("Resources")
            ]
        ),
        // Dev tool: turns the phpstorm-stubs directory into a compact JSON symbol index.
        .executableTarget(
            name: "phpstubgen",
            dependencies: ["CodeEditLang", "CodeEditLangPHP"]
        ),
        // Authoring tool for declarative language extensions (init/validate/pack/schema).
        .executableTarget(
            name: "codeedit-ext",
            dependencies: ["CodeEditLang"]
        ),
        .testTarget(
            name: "CodeEditLangTests",
            dependencies: ["CodeEditLangPHP", "CodeEditSourceEditor"]
        ),
    ]
)
