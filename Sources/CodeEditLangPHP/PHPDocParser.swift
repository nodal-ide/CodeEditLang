import Foundation

/// A parsed PHPDoc block.
public struct PHPDocBlock: Equatable, Sendable {
    /// The first prose paragraph.
    public let summary: String?
    /// Prose paragraphs after the summary.
    public let description: String?
    /// Tag lines in source order.
    public let tags: [PHPDocTag]
    /// The cleaned source text, retained as a fallback for unsupported constructs.
    public let raw: String

    public var isEmpty: Bool {
        summary == nil && description == nil && tags.isEmpty
    }

    public var parameters: [PHPDocTag] {
        tags.filter { $0.name == "param" || $0.name.hasSuffix("-param") }
    }

    public var returnTag: PHPDocTag? {
        tags.first { $0.name == "return" || $0.name.hasSuffix("-return") }
    }

    public var throwsTags: [PHPDocTag] {
        tags.filter { $0.name == "throws" || $0.name.hasSuffix("-throws") }
    }

    public func tags(named name: String) -> [PHPDocTag] {
        tags.filter { $0.name == name.lowercased() }
    }
}

/// A single PHPDoc tag with the common fields used by hover rendering.
public struct PHPDocTag: Equatable, Sendable {
    /// The tag name without the leading `@`, lowercased.
    public let name: String
    /// The complete content after the tag name. Multiline values preserve line breaks.
    public let content: String
    /// The declared type for tags such as `@param`, `@return`, and `@throws`.
    public let type: String?
    /// The declared variable for tags such as `@param` and `@var`.
    public let variable: String?
    /// The prose after the type and variable. Line wraps are normalized to spaces.
    public let description: String?
}

/// Parses the cleaned contents of a PHPDoc block into a semantic model.
public enum PHPDocParser {
    /// Parses a docblock. The input may omit `/**` and `*/`; leading `*` line prefixes are tolerated.
    public static func parse(_ source: String) -> PHPDocBlock? {
        var raw = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let isRawComment = raw.hasPrefix("/**")
        if isRawComment {
            raw.removeFirst(3)
        }
        if raw.hasSuffix("*/") {
            raw.removeLast(2)
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !raw.isEmpty else { return nil }

        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { cleanLine(String($0), stripLeadingStar: isRawComment) }
        let (prose, tagLines) = split(lines)
        let paragraphs = proseParagraphs(prose)
        let tags = parseTags(tagLines)

        let block = PHPDocBlock(
            summary: paragraphs.first,
            description: paragraphs.dropFirst().isEmpty ? nil : paragraphs.dropFirst().joined(separator: "\n\n"),
            tags: tags,
            raw: raw
        )
        return block.isEmpty ? nil : block
    }

    private static func cleanLine(_ line: String, stripLeadingStar: Bool = false) -> String {
        let leadingTrimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let text: String
        if stripLeadingStar || leadingTrimmed.count < line.count, leadingTrimmed.hasPrefix("*") {
            var content = leadingTrimmed.dropFirst()
            if content.hasPrefix(" ") {
                content = content.dropFirst()
            }
            text = String(content)
        } else {
            text = line
        }
        return text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    private static func split(_ lines: [String]) -> (prose: [String], tags: [String]) {
        var prose: [String] = []
        var tags: [String] = []
        var inTags = false

        for line in lines {
            if !inTags, parseTagLine(line) != nil {
                inTags = true
            }
            if inTags {
                tags.append(line)
            } else {
                prose.append(line)
            }
        }
        return (prose, tags)
    }

    private static func proseParagraphs(_ lines: [String]) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []

        func flush() {
            let text = current
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !text.isEmpty {
                paragraphs.append(text)
            }
            current.removeAll()
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                current.append(line)
            }
        }
        flush()
        return paragraphs
    }

    private static func parseTags(_ lines: [String]) -> [PHPDocTag] {
        var tags: [PHPDocTag] = []
        var name: String?
        var contentLines: [String] = []

        func flush() {
            guard let name else { return }
            let firstLineWasEmpty = contentLines.first?
                .trimmingCharacters(in: .whitespaces)
                .isEmpty ?? true
            var content = contentLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            if !firstLineWasEmpty {
                content = content.trimmingCharacters(in: .whitespaces)
            }
            tags.append(makeTag(name: name, content: content))
            contentLines.removeAll()
        }

        for line in lines {
            if let parsed = parseTagLine(line) {
                flush()
                name = parsed.name
                contentLines = [parsed.content]
            } else if name != nil {
                contentLines.append(line)
            }
        }
        flush()
        return tags
    }

    private static func parseTagLine(_ line: String) -> (name: String, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@") else { return nil }

        let afterAt = trimmed.dropFirst()
        let tagName = afterAt.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !tagName.isEmpty else { return nil }

        let following = afterAt.dropFirst(tagName.count)
        guard following.isEmpty || following.first?.isWhitespace == true else { return nil }

        return (String(tagName).lowercased(), String(following))
    }

    private static func makeTag(name: String, content: String) -> PHPDocTag {
        guard parsesType(name), !content.isEmpty else {
            return PHPDocTag(
                name: name,
                content: content,
                type: nil,
                variable: nil,
                description: nil
            )
        }

        var remainder = Substring(content)
        var type: String?
        var variable: String?
        let returnsValue = name == "return" || name.hasSuffix("-return")

        if let first = takeToken(&remainder) {
            if isVariableToken(first), !returnsValue {
                variable = normalizedVariable(first)
            } else {
                type = first
                if first.hasSuffix(":"), first.hasPrefix("callable(") || first.hasPrefix("\\Closure(") {
                    if let callableReturn = takeToken(&remainder) {
                        type? += " \(callableReturn)"
                    }
                }
                let rest = remainder.drop(while: \.isWhitespace)
                if isVariableToken(String(rest.prefix { !$0.isWhitespace })) {
                    variable = takeToken(&remainder).map(normalizedVariable)
                }
            }
        }

        let description = normalize(remainder)
        return PHPDocTag(
            name: name,
            content: content,
            type: type,
            variable: variable,
            description: description
        )
    }

    private static func isVariableToken(_ token: String) -> Bool {
        var token = Substring(token)
        while token.first == "&" || token.hasPrefix("...") {
            if token.first == "&" {
                token = token.dropFirst()
            } else {
                token = token.dropFirst(3)
            }
        }
        return token.hasPrefix("$")
    }

    private static func normalizedVariable(_ token: String) -> String {
        var token = Substring(token)
        while token.first == "&" || token.hasPrefix("...") {
            if token.first == "&" {
                token = token.dropFirst()
            } else {
                token = token.dropFirst(3)
            }
        }
        return String(token)
    }

    private static func parsesType(_ name: String) -> Bool {
        let typeTags = ["param", "return", "throws", "var", "property", "property-read", "property-write"]
        return typeTags.contains(name) || typeTags.contains { name.hasSuffix("-\($0)") }
    }

    private static func takeToken(_ text: inout Substring) -> String? {
        text = text.drop(while: { $0.isWhitespace })
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return nil }

        var depth = 0
        var end = text.endIndex
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if "<([{".contains(character) {
                depth += 1
            } else if ">)]}".contains(character) {
                depth = max(0, depth - 1)
            } else if character.isWhitespace, depth == 0 {
                end = index
                break
            }
            index = text.index(after: index)
        }

        let token = String(text[start..<end])
        text = text[end...]
        return token.isEmpty ? nil : token
    }

    private static func normalize(_ text: Substring) -> String? {
        let normalized = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}
