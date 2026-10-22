//
//  main.swift
//  codeedit-ext
//
//  Authoring tool for declarative language extensions (packs).
//
//  Usage:
//    codeedit-ext init <dir> [--id <id>] [--name <name>] [--language <lang>]
//    codeedit-ext validate <dir>
//    codeedit-ext pack <dir> [--output <file.zip>]
//    codeedit-ext schema
//

import Foundation
import CodeEditLang

/// Raw URL of the published JSON schema.
let rawSchemaURL = "https://raw.githubusercontent.com/nodal-ide/CodeEditLang/master/Schema/language-extension.schema.json"

// MARK: - Entry point

func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        printUsage()
        exit(0)
    }

    switch command {
    case "init":
        runInit(Array(arguments.dropFirst()))
    case "validate":
        runValidate(Array(arguments.dropFirst()))
    case "pack":
        runPack(Array(arguments.dropFirst()))
    case "schema":
        print(LanguageExtensionSchema.json)
    case "help", "-h", "--help":
        printUsage()
    default:
        FileHandle.standardError.write(Data("Unknown command: \(command)\n".utf8))
        printUsage()
        exit(1)
    }
}

// MARK: - Commands

func runInit(_ args: [String]) {
    guard let directoryArgument = args.first(where: { !$0.hasPrefix("--") }) else {
        fail("init requires a target directory, e.g. `codeedit-ext init MyPack`")
    }
    let options = parseOptions(args)
    let directory = URL(fileURLWithPath: directoryArgument, isDirectory: true)
    let directoryName = directory.lastPathComponent
    let identifier = options["id"] ?? "com.example.\(directoryName.lowercased())"
    let name = options["name"] ?? directoryName
    let language = options["language"] ?? "php"

    do {
        let fileManager = FileManager.default
        let symbolsDirectory = directory.appending(path: "symbols", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: symbolsDirectory, withIntermediateDirectories: true)

        let manifest = LanguageExtensionManifest(
            id: identifier,
            name: name,
            version: "0.1.0",
            type: "languagePack",
            description: "\(name) language extension.",
            author: NSFullUserName(),
            languages: [language],
            framework: "\(directoryName.lowercased())/framework",
            activation: .init(framework: .init(file: "composer.json",
                                               requires: ["\(directoryName.lowercased())/framework": ">=1"])),
            contributes: .init(symbols: ["symbols/symbols.json"])
        )
        try writeManifest(manifest, to: directory.appending(path: "extension.json"))

        try sampleSymbols.write(
            to: symbolsDirectory.appending(path: "symbols.json"),
            atomically: true,
            encoding: .utf8
        )
        try readme(name: name, identifier: identifier, language: language).write(
            to: directory.appending(path: "README.md"),
            atomically: true,
            encoding: .utf8
        )

        print("Created \(directoryName)/")
        print("  extension.json")
        print("  symbols/symbols.json")
        print("  README.md")
        print("")
        print("Next: edit the files, then run `codeedit-ext validate \(directoryName)`")
        print("and `codeedit-ext pack \(directoryName)`.")
    } catch {
        fail("Failed to create extension: \(error.localizedDescription)")
    }
}

func runValidate(_ args: [String]) {
    guard let directoryArgument = args.first(where: { !$0.hasPrefix("--") }) else {
        fail("validate requires a directory, e.g. `codeedit-ext validate MyPack`")
    }
    let directory = URL(fileURLWithPath: directoryArgument, isDirectory: true)

    let manifestURL = directory.appending(path: "extension.json")
    guard let data = try? Data(contentsOf: manifestURL) else {
        fail("No extension.json found in \(directory.path).")
    }

    let manifest: LanguageExtensionManifest
    do {
        manifest = try JSONDecoder().decode(LanguageExtensionManifest.self, from: data)
    } catch {
        fail("extension.json is invalid: \(LanguageExtensionValidator.describe(error))")
    }

    // The app validates with the same rules plus its built-in language catalog; the CLI has no
    // grammar knowledge, so it only reports structural issues.
    let result = LanguageExtensionValidator.validate(manifest: manifest, root: directory)

    for warning in result.warnings { print("warning: \(warning.description)") }
    for error in result.errors { print("error: \(error.description)") }

    if result.isValid {
        print("✓ \(manifest.name) is valid\(result.warnings.isEmpty ? "" : " (with warnings)").")
        exit(0)
    }
    exit(1)
}

func runPack(_ args: [String]) {
    guard let directoryArgument = args.first(where: { !$0.hasPrefix("--") }) else {
        fail("pack requires a directory, e.g. `codeedit-ext pack MyPack`")
    }
    let directory = URL(fileURLWithPath: directoryArgument, isDirectory: true)
    let options = parseOptions(args)

    let outputPath = options["output"] ?? "\(directory.lastPathComponent).zip"
    let outputURL = URL(fileURLWithPath: outputPath)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = directory.deletingLastPathComponent()
    process.arguments = [
        "-r", "-q", "-X",
        outputURL.path,
        directory.lastPathComponent,
        "-x", "*.DS_Store"
    ]

    do {
        try process.run()
    } catch {
        fail("Could not run zip: \(error.localizedDescription)")
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fail("zip failed with status \(process.terminationStatus).")
    }

    print("Packed \(directory.lastPathComponent) -> \(outputPath)")
    print("Install it with CodeEdit ▸ Extensions ▸ Add from Archive…")
}

// MARK: - Helpers

func parseOptions(_ args: [String]) -> [String: String] {
    var options: [String: String] = [:]
    var index = 0
    while index < args.count {
        let argument = args[index]
        if argument.hasPrefix("--"), index + 1 < args.count {
            options[String(argument.dropFirst(2))] = args[index + 1]
            index += 2
        } else {
            index += 1
        }
    }
    return options
}

func writeManifest(_ manifest: LanguageExtensionManifest, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    let encoded = try encoder.encode(manifest)
    var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    object["$schema"] = rawSchemaURL
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func printUsage() {
    print(
        """
        codeedit-ext — author CodeEdit language extensions

        USAGE:
          codeedit-ext init <dir> [--id <id>] [--name <name>] [--language <lang>]
          codeedit-ext validate <dir>
          codeedit-ext pack <dir> [--output <file.zip>]
          codeedit-ext schema

        COMMANDS:
          init       Scaffold a new language extension.
          validate   Validate extension.json and its symbol files.
          pack       Zip an extension for installation.
          schema     Print the JSON schema for extension.json.
        """
    )
}

// MARK: - Templates

let sampleSymbols = """
{
  "language": "php",
  "symbols": [
    {
      "name": "component",
      "kind": "function",
      "signature": "function component(string $name, array $data = []): string",
      "parameters": ["string $name", "array $data = []"],
      "documentation": "Render a named component."
    },
    {
      "name": "Component",
      "kind": "class",
      "namespace": "Example",
      "documentation": "Base component class."
    }
  ]
}
"""

func readme(name: String, identifier: String, language: String) -> String {
    """
    # \(name)

    A CodeEdit language extension (`\(identifier)`) providing `\(language)` completion, hover and
    go-to-definition.

    ## Files

    - `extension.json` — the manifest (id, name, languages, activation, contributes).
    - `symbols/symbols.json` — the symbols the pack contributes.

    ## Validate & pack

    ```sh
    codeedit-ext validate .
    codeedit-ext pack .
    ```

    Then install the resulting `.zip` via **CodeEdit ▸ Extensions ▸ Add from Archive…**.

    ## Notes

    - Declare global helper functions **without** a `namespace` so they complete unqualified.
    - Activation can be a literal marker file (`activation.files`) or a package requirement
      (`activation.framework`); wildcards in `files` are ignored.
    """
}

main()
