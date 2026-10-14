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

/// Raw URL of the published JSON schema (hosted in this repo, our fork).
let rawSchemaURL = "https://raw.githubusercontent.com/upperdo/CodeEditLang/master/Schema/language-extension.schema.json"

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
        print(schemaJSON)
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

    var errors: [String] = []
    var warnings: [String] = []

    let manifestURL = directory.appending(path: "extension.json")
    let data: Data
    do {
        data = try Data(contentsOf: manifestURL)
    } catch {
        fail("No extension.json found in \(directory.path).")
    }

    let manifest: LanguageExtensionManifest
    do {
        manifest = try JSONDecoder().decode(LanguageExtensionManifest.self, from: data)
    } catch {
        fail("extension.json is invalid: \(describe(error))")
    }

    if manifest.id.isEmpty { errors.append("`id` must not be empty.") }
    if !manifest.id.contains(".") { warnings.append("`id` should be a reverse-DNS id, e.g. com.example.pack.") }
    if manifest.name.isEmpty { errors.append("`name` must not be empty.") }
    if let schemaVersion = manifest.schemaVersion, schemaVersion != 1 {
        warnings.append("Unknown `schemaVersion` \(schemaVersion); expected 1.")
    }

    if let url = manifest.url, URL(string: url) == nil {
        warnings.append("`url` is not a valid URL: \(url).")
    }
    if let icon = manifest.icon,
       !FileManager.default.fileExists(atPath: directory.appending(path: icon).path) {
        warnings.append("`icon` file not found: \(icon).")
    }

    if let files = manifest.activation?.files {
        for pattern in files where pattern.contains("*") || pattern.contains("?") {
            warnings.append("`activation.files` pattern '\(pattern)' contains a wildcard and will be ignored.")
        }
    }

    let languages = manifest.languages ?? []
    if languages.isEmpty { warnings.append("No `languages` declared — the pack will never activate.") }

    let symbolFiles = manifest.contributes?.symbols ?? []
    if symbolFiles.isEmpty {
        warnings.append("No `contributes.symbols` — the pack contributes nothing.")
    }
    for file in symbolFiles {
        let url = directory.appending(path: file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errors.append("Symbol file not found: \(file)")
            continue
        }
        do {
            let pack = try JSONDecoder().decode(LanguageSymbolPack.self, from: Data(contentsOf: url))
            if pack.symbols.isEmpty {
                warnings.append("Symbol file has no symbols: \(file)")
            }
            for symbol in pack.symbols where symbol.name.isEmpty {
                errors.append("A symbol in \(file) has an empty name.")
            }
        } catch {
            errors.append("Symbol file \(file) is invalid: \(describe(error))")
        }
    }

    for warning in warnings { print("warning: \(warning)") }
    for error in errors { print("error: \(error)") }

    if errors.isEmpty {
        print("✓ \(manifest.name) is valid\(warnings.isEmpty ? "" : " (with warnings)").")
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

func describe(_ error: Error) -> String {
    if let decodingError = error as? DecodingError {
        switch decodingError {
        case .keyNotFound(let key, _):
            return "missing key '\(key.stringValue)'"
        case .typeMismatch(_, let context):
            return "type mismatch at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted(let context):
            return "data corrupted at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        default:
            return decodingError.localizedDescription
        }
    }
    return error.localizedDescription
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

// MARK: - JSON Schema

let schemaJSON = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://raw.githubusercontent.com/upperdo/CodeEditLang/master/Schema/language-extension.schema.json",
  "title": "CodeEdit Language Extension",
  "type": "object",
  "required": ["id", "name"],
  "properties": {
    "$schema": { "type": "string", "format": "uri" },
    "schemaVersion": { "type": "integer", "const": 1 },
    "id": { "type": "string", "minLength": 1, "description": "Reverse-DNS identifier, e.g. com.example.pack." },
    "name": { "type": "string", "minLength": 1 },
    "version": { "type": "string" },
    "type": { "type": "string", "enum": ["languagePack", "languageProvider", "settings", "sidebar", "theme", "action"] },
    "description": { "type": "string" },
    "author": { "type": "string" },
    "url": { "type": "string", "format": "uri" },
    "icon": { "type": "string", "description": "Path to an image, relative to the pack root." },
    "languages": { "type": "array", "items": { "type": "string" }, "minItems": 1 },
    "framework": { "type": "string", "description": "Framework this pack targets, e.g. laravel/framework." },
    "activation": {
      "type": "object",
      "properties": {
        "files": {
          "type": "array",
          "items": { "type": "string" },
          "description": "Literal workspace-relative marker paths. Wildcards are ignored."
        },
        "framework": {
          "type": "object",
          "properties": {
            "file": { "type": "string", "default": "composer.json" },
            "requires": { "type": "object", "additionalProperties": { "type": "string" } }
          }
        }
      }
    },
    "contributes": {
      "type": "object",
      "properties": {
        "symbols": { "type": "array", "items": { "type": "string" } },
        "snippets": { "type": "array", "items": { "type": "string" } },
        "stubRoots": { "type": "array", "items": { "type": "string" } }
      }
    }
  },
  "additionalProperties": true
}
"""

main()
