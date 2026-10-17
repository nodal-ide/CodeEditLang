//
//  PHPDiagnostics.swift
//  CodeEditLangPHP
//
//  Code-quality diagnostics for the native PHP engine (SwiftLint-style rules).
//

import Foundation
import CodeEditSourceEditor
import CodeEditLang

/// Configuration for the native PHP diagnostics engine. Injected by the app (which owns user settings).
public struct PHPDiagnosticsConfig: Sendable {
    public var classLength: Int = 250
    public var methodLength: Int = 50
    public var fileLength: Int = 500
    public var parameterCount: Int = 5
    public var complexity: Int = 10
    /// `declare(strict_types=1);` hint.
    public var requireStrictTypes: Bool = true
    /// `TODO`/`FIXME` hints.
    public var reportTodos: Bool = true
    /// Rule ids to disable, e.g. `php.style.todo`.
    public var disabledRules: Set<String> = []
    /// Path substrings/globs to skip entirely (vendor, generated files).
    public var skipPatterns: [String] = ["/vendor/", ".generated."]

    public init() {}

    public static var `default`: PHPDiagnosticsConfig { PHPDiagnosticsConfig() }
}

/// A single code-quality issue found by the engine.
public struct PHPDiagnostic: Sendable {
    public let ruleID: String
    public let range: NSRange
    public let severity: EditorDiagnosticSeverity
    public let message: String
    public let line: Int
}

/// Rule identifiers. Stable strings so they can be configured/suppressed.
public enum PHPRule {
    public static let lengthClass = "php.length.class"
    public static let lengthMethod = "php.length.method"
    public static let lengthFile = "php.length.file"
    public static let parameterCount = "php.style.parameterCount"
    public static let complexity = "php.complexity"
    public static let strictTypes = "php.strictTypes"
    public static let todo = "php.style.todo"
}

/// Runs the built-in PHP code-quality rules over a parsed file.
public enum PHPDiagnosticsEngine {
    public static func run(
        source: String,
        info: PHPFileSymbols,
        fileURL: URL,
        settings: PHPDiagnosticsConfig = .default
    ) -> [PHPDiagnostic] {
        guard !isSkipped(fileURL: fileURL, settings: settings) else { return [] }

        let lineStarts = lineStartOffsets(in: source)
        let suppressed = suppressionMap(source: source)

        var result: [PHPDiagnostic] = []
        func add(_ diagnostic: PHPDiagnostic) {
            guard !settings.disabledRules.contains(diagnostic.ruleID) else { return }
            if suppressed[diagnostic.ruleID]?.contains(diagnostic.line) == true
                || suppressed["*"]?.contains(diagnostic.line) == true {
                return
            }
            result.append(diagnostic)
        }

        func line(at offset: Int) -> Int { lineNumber(for: offset, in: lineStarts) }
        func span(of range: NSRange) -> Int { lineSpan(of: range, in: lineStarts) }

        // File length.
        let fileLines = lineStarts.count
        if fileLines > settings.fileLength {
            add(PHPDiagnostic(
                ruleID: PHPRule.lengthFile,
                range: NSRange(location: 0, length: 0),
                severity: .warning,
                message: "File is \(fileLines) lines long (max \(settings.fileLength))",
                line: 1
            ))
        }

        // Per-symbol rules.
        for symbol in info.symbols {
            let symbolLine = line(at: symbol.nameRange.location)
            let symbolSpan = span(of: symbol.fullRange)

            switch symbol.kind {
            case .class, .interface, .trait, .enum:
                if symbolSpan > settings.classLength {
                    add(PHPDiagnostic(
                        ruleID: PHPRule.lengthClass,
                        range: symbol.nameRange,
                        severity: .warning,
                        message: "Type '\(symbol.name)' is \(symbolSpan) lines long (max \(settings.classLength))",
                        line: symbolLine
                    ))
                }
            case .function, .method:
                if symbolSpan > settings.methodLength {
                    let noun = symbol.kind == .method ? "Method" : "Function"
                    add(PHPDiagnostic(
                        ruleID: PHPRule.lengthMethod,
                        range: symbol.nameRange,
                        severity: .warning,
                        message: "\(noun) '\(symbol.name)' is \(symbolSpan) lines long (max \(settings.methodLength))",
                        line: symbolLine
                    ))
                }
                if symbol.parameters.count > settings.parameterCount {
                    add(PHPDiagnostic(
                        ruleID: PHPRule.parameterCount,
                        range: symbol.nameRange,
                        severity: .warning,
                        message: "'\(symbol.name)' has \(symbol.parameters.count) parameters (max \(settings.parameterCount))",
                        line: symbolLine
                    ))
                }
                let complexity = cyclomaticComplexity(in: substring(of: symbol.fullRange, in: source))
                if complexity > settings.complexity {
                    add(PHPDiagnostic(
                        ruleID: PHPRule.complexity,
                        range: symbol.nameRange,
                        severity: .warning,
                        message: "'\(symbol.name)' has complexity \(complexity) (max \(settings.complexity))",
                        line: symbolLine
                    ))
                }
            default:
                continue
            }
        }

        // `declare(strict_types=1);`.
        if settings.requireStrictTypes, source.contains("<?php"), !hasStrictTypes(source) {
            add(PHPDiagnostic(
                ruleID: PHPRule.strictTypes,
                range: NSRange(location: 0, length: 0),
                severity: .hint,
                message: "Missing 'declare(strict_types=1);'",
                line: 1
            ))
        }

        // TODO / FIXME comments.
        if settings.reportTodos {
            for (offset, range) in todoLocations(in: source) {
                add(PHPDiagnostic(
                    ruleID: PHPRule.todo,
                    range: range,
                    severity: .hint,
                    message: "Found a TODO/FIXME comment",
                    line: line(at: offset)
                ))
            }
        }

        return result
    }

    // MARK: - Rule helpers

    private static func hasStrictTypes(_ source: String) -> Bool {
        // Look only at the top of the file (before the first `namespace`/`class`).
        let head = source.prefix(2000)
        return head.contains("declare(strict_types=1)") || head.contains("declare(strict_types = 1)")
    }

    private static func cyclomaticComplexity(in body: String) -> Int {
        let patterns = ["\\bif\\b", "\\belseif\\b", "\\belse\\b", "\\bfor\\b", "\\bforeach\\b",
                        "\\bwhile\\b", "\\bcase\\b", "\\bcatch\\b", "&&", "\\|\\|", "\\?\\?"]
        var complexity = 1
        for pattern in patterns {
            complexity += body.matches(of: pattern)
        }
        return complexity
    }

    private static func todoLocations(in source: String) -> [(Int, NSRange)] {
        var result: [(Int, NSRange)] = []
        let ns = source as NSString
        var line = 0
        var lineStart = 0
        var index = 0
        while index <= ns.length {
            let atEnd = index == ns.length
            if atEnd || ns.character(at: index) == 0x0A {
                let lineRange = NSRange(location: lineStart, length: index - lineStart)
                let lineText = ns.substring(with: lineRange)
                if let comment = commentStart(in: lineText),
                   let todo = firstTodo(in: lineText, after: comment) {
                    result.append((lineStart + todo, NSRange(location: lineStart + todo, length: 4)))
                }
                line += 1
                lineStart = index + 1
            }
            index += 1
        }
        return result
    }

    /// Offset of the first `//` or `#` comment marker in a line, if any.
    private static func commentStart(in line: String) -> Int? {
        if let range = line.range(of: "//") { return line.distance(from: line.startIndex, to: range.lowerBound) }
        if let range = line.range(of: "#") { return line.distance(from: line.startIndex, to: range.lowerBound) }
        return nil
    }

    private static func firstTodo(in line: String, after index: Int) -> Int? {
        let rest = String(line.dropFirst(index)).uppercased()
        for marker in ["TODO", "FIXME"] {
            if let range = rest.range(of: marker) {
                return index + rest.distance(from: rest.startIndex, to: range.lowerBound)
            }
        }
        return nil
    }

    // MARK: - Suppression

    /// Builds a map of rule id (or `*`) -> the line numbers it is suppressed on.
    private static func suppressionMap(source: String) -> [String: Set<Int>] {
        var map: [String: Set<Int>] = [:]
        let lines = source.components(separatedBy: .newlines)
        for (idx, line) in lines.enumerated() {
            guard let range = line.range(of: "@codeedit-ignore") else { continue }
            var rest = line[range.upperBound...]
            var target = idx + 1
            if rest.hasPrefix("-next-line") {
                rest = rest.dropFirst("-next-line".count)
                target += 1
            }
            let ids = rest
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
                .map(String.init)
                .filter { $0.hasPrefix("php.") }
            let rules = ids.isEmpty ? ["*"] : ids
            for rule in rules {
                map[rule, default: []].insert(target)
            }
        }
        return map
    }

    // MARK: - Path skipping

    private static func isSkipped(fileURL: URL, settings: PHPDiagnosticsConfig) -> Bool {
        let path = fileURL.path(percentEncoded: false)
        return settings.skipPatterns.contains { !$0.isEmpty && path.contains($0) }
    }

    // MARK: - Line helpers

    static func lineStartOffsets(in source: String) -> [Int] {
        let ns = source as NSString
        var starts: [Int] = [0]
        var index = 0
        while index < ns.length {
            if ns.character(at: index) == 0x0A { starts.append(index + 1) }
            index += 1
        }
        return starts
    }

    static func lineNumber(for offset: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(1, low)
    }

    static func lineSpan(of range: NSRange, in starts: [Int]) -> Int {
        guard range.length > 0 else { return 1 }
        let start = lineNumber(for: range.location, in: starts)
        let end = lineNumber(for: range.location + range.length - 1, in: starts)
        return max(1, end - start + 1)
    }

    private static func substring(of range: NSRange, in source: String) -> String {
        let ns = source as NSString
        let location = min(max(range.location, 0), ns.length)
        let length = min(max(range.length, 0), ns.length - location)
        return ns.substring(with: NSRange(location: location, length: length))
    }
}

private extension String {
    /// Number of matches of a regular expression in the receiver.
    func matches(of pattern: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: self, range: NSRange(location: 0, length: (self as NSString).length))
    }
}
