//
//  main.swift
//  phpstubgen
//
//  Dev tool: parse a phpstorm-stubs directory with our PHP parser and emit a compact
//  JSON symbol index that gets bundled as a resource in CodeEditLangPHP.
//
//  Usage: swift run phpstubgen <stub-directory> <output.json>
//

import Foundation
import CodeEditLang
import CodeEditLangPHP

struct StubSymbol: Codable {
    let name: String
    let kind: String
    let namespace: String?
    let container: String?
    let parameters: [String]
    let documentation: String?
}

func shortDoc(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    // Strip HTML tags and collapse whitespace.
    let withoutTags = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    let collapsed = withoutTags
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !collapsed.isEmpty else { return nil }
    // Keep only the first line/paragraph, capped.
    let firstLine = collapsed
        .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        .first
        .map(String.init) ?? collapsed
    return String(firstLine.prefix(200))
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: phpstubgen <stub-directory> <output.json>\n".utf8))
    exit(2)
}

let root = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])

let fileManager = FileManager.default
var symbols: [StubSymbol] = []
var fileCount = 0

let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil)
while let file = enumerator?.nextObject() as? URL {
    guard file.pathExtension == "php" else { continue }
    guard let data = try? Data(contentsOf: file),
          let source = String(data: data, encoding: .utf8) else { continue }
    fileCount += 1
    let info = PHPFileParser.parse(source, fileURL: file)
    for symbol in info.symbols {
        symbols.append(
            StubSymbol(
                name: symbol.name,
                kind: symbol.kind.rawValue,
                namespace: symbol.namespace,
                container: symbol.container,
                parameters: symbol.parameters,
                documentation: shortDoc(symbol.documentation)
            )
        )
    }
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]
let encoded = try encoder.encode(symbols)
try encoded.write(to: output)

FileHandle.standardError.write(Data("parsed \(fileCount) stub files -> \(symbols.count) symbols\n".utf8))