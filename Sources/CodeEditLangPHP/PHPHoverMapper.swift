import Foundation
import CodeEditLang
import CodeEditSourceEditor

public enum PHPHoverMapper {
    public static func content(for symbol: SymbolInfo) -> HoverContent {
        .document(document(for: symbol))
    }

    public static func document(for symbol: SymbolInfo) -> HoverDocument {
        let docBlock = symbol.documentation.flatMap(PHPDocParser.parse)
        let inheritsDocumentation = containsInheritDoc(symbol.documentation)
        let deprecated = docBlock?.tags.first { baseName(of: $0.name) == "deprecated" }
        let signatureParameters = symbol.parameters.compactMap(parseSignatureParameter)

        var blocks = leadingBlocks(
            inheritsDocumentation: inheritsDocumentation,
            deprecated: deprecated
        )
        if let signature = signature(for: symbol) {
            blocks.append(.signature(HoverCode(text: signature, language: "php")))
        }
        blocks.append(
            contentsOf: contentBlocks(
                for: symbol,
                docBlock: docBlock,
                inheritsDocumentation: inheritsDocumentation,
                signatureParameters: signatureParameters
            )
        )
        blocks.append(contentsOf: referenceBlocks(for: docBlock))

        return HoverDocument(header: header(for: symbol, deprecated: deprecated != nil), blocks: blocks)
    }

    private static func header(for symbol: SymbolInfo, deprecated: Bool) -> HoverHeader {
        var badges: [HoverBadge] = []
        if deprecated {
            badges.append(HoverBadge(text: "deprecated", tone: .warning))
        }
        if let visibility = nonEmpty(symbol.visibility) {
            badges.append(HoverBadge(text: visibility, tone: .neutral))
        }

        return HoverHeader(
            title: displayName(for: symbol),
            subtitle: nonEmpty(symbol.container) ?? nonEmpty(symbol.namespace),
            systemImageName: systemImageName(for: symbol.kind),
            tone: tone(for: symbol.kind),
            badges: badges
        )
    }

}

private extension PHPHoverMapper {
    private static func leadingBlocks(
        inheritsDocumentation: Bool,
        deprecated: PHPDocTag?
    ) -> [HoverBlock] {
        var blocks: [HoverBlock] = []
        if inheritsDocumentation {
            blocks.append(
                .notice(
                    HoverNotice(
                        title: "Inherited documentation",
                        message: "Documentation is inherited from the parent declaration.",
                        tone: .info
                    )
                )
            )
        }
        if let deprecated {
            blocks.append(.notice(deprecatedNotice(deprecated)))
        }
        return blocks
    }

    private static func contentBlocks(
        for symbol: SymbolInfo,
        docBlock: PHPDocBlock?,
        inheritsDocumentation: Bool,
        signatureParameters: [SignatureParameter]
    ) -> [HoverBlock] {
        var blocks: [HoverBlock] = []
        if let prose = prose(for: docBlock, inheritsDocumentation: inheritsDocumentation) {
            blocks.append(.markdown(prose))
        }
        if let parameters = parameterDefinitions(
            for: symbol,
            docBlock: docBlock,
            signature: signatureParameters
        ) {
            blocks.append(.definitionList(parameters))
        }
        if let returns = definitionList(
            title: "Returns",
            tags: tags(in: docBlock, named: "return"),
            tone: .accent
        ) {
            blocks.append(.definitionList(returns))
        }
        if let throwsBlock = definitionList(
            title: "Throws",
            tags: tags(in: docBlock, named: "throws"),
            tone: .warning
        ) {
            blocks.append(.definitionList(throwsBlock))
        }
        if let variables = definitionList(
            title: "Type",
            tags: tags(in: docBlock, named: "var"),
            tone: .type
        ) {
            blocks.append(.definitionList(variables))
        }
        return blocks
    }

    private static func referenceBlocks(for docBlock: PHPDocBlock?) -> [HoverBlock] {
        var blocks: [HoverBlock] = []
        for tag in tags(in: docBlock, named: "example") {
            blocks.append(contentsOf: exampleBlocks(for: tag.content))
        }

        let references = tags(in: docBlock, named: "see").map(reference(for:))
        if !references.isEmpty {
            blocks.append(.links(references))
        }

        let metadata = metadata(for: docBlock)
        if !metadata.isEmpty {
            blocks.append(.metadata(metadata))
        }
        return blocks
    }

    private static func displayName(for symbol: SymbolInfo) -> String {
        switch symbol.kind {
        case .property, .variable:
            return symbol.name.hasPrefix("$") ? symbol.name : "$\(symbol.name)"
        default:
            return symbol.name
        }
    }

    private static func signature(for symbol: SymbolInfo) -> String? {
        switch symbol.kind {
        case .function, .method:
            if let signature = nonEmpty(symbol.signature), signature.contains("(") {
                return signature
            }
            let parameters = symbol.parameters.joined(separator: ", ")
            return "\(symbol.kind.rawValue) \(symbol.name)(\(parameters))"
        case .property, .variable:
            return [nonEmpty(symbol.signature), displayName(for: symbol)]
                .compactMap { $0 }
                .joined(separator: " ")
        case .constant:
            if let signature = nonEmpty(symbol.signature) {
                return signature
            }
            return "const \(symbol.name)"
        case .namespace:
            return "namespace \(symbol.fullyQualifiedName)"
        case .class, .trait, .interface, .enum:
            if let signature = nonEmpty(symbol.signature) {
                return signature
            }
            return "\(symbol.kind.rawValue) \(symbol.fullyQualifiedName)"
        }
    }

    private static func prose(for docBlock: PHPDocBlock?, inheritsDocumentation: Bool) -> String? {
        var paragraphs = [docBlock?.summary, docBlock?.description].compactMap { nonEmpty($0) }
        if inheritsDocumentation {
            paragraphs = paragraphs.map { removingInheritMarkers(from: $0) }.filter { !$0.isEmpty }
        }
        let text = paragraphs.joined(separator: "\n\n")
        return nonEmpty(linkifiedMarkdown(text))
    }

    private static func parameterDefinitions(
        for symbol: SymbolInfo,
        docBlock: PHPDocBlock?,
        signature: [SignatureParameter]
    ) -> HoverDefinitionList? {
        guard symbol.kind == .function || symbol.kind == .method || !signature.isEmpty else { return nil }

        var items: [HoverDefinitionItem] = []
        var documented = Set<String>()

        for tag in tags(in: docBlock, named: "param") {
            if let variable = nonEmpty(tag.variable) {
                documented.insert(variable)
            }
            let matching = signature.first { $0.name == tag.variable }
            let item = HoverDefinitionItem(
                term: nonEmpty(tag.variable),
                type: nonEmpty(tag.type) ?? matching?.type,
                description: nonEmpty(linkifiedMarkdown(tag.description ?? "")),
                tone: .neutral
            )
            if item.term != nil || item.type != nil || item.description != nil {
                items.append(item)
            }
        }

        for parameter in signature where !documented.contains(parameter.name) {
            items.append(
                HoverDefinitionItem(
                    term: parameter.name,
                    type: parameter.type,
                    description: nil,
                    tone: .neutral
                )
            )
        }

        guard !items.isEmpty else { return nil }
        return HoverDefinitionList(title: "Parameters", items: items)
    }

    private static func definitionList(
        title: String,
        tags: [PHPDocTag],
        tone: HoverTone
    ) -> HoverDefinitionList? {
        let items = tags.compactMap { tag -> HoverDefinitionItem? in
            let type = nonEmpty(tag.type) ?? nonEmpty(tag.variable)
            let description = nonEmpty(linkifiedMarkdown(tag.description ?? ""))
            guard type != nil || description != nil else { return nil }
            return HoverDefinitionItem(term: nil, type: type, description: description, tone: tone)
        }
        guard !items.isEmpty else { return nil }
        return HoverDefinitionList(title: title, items: items)
    }

    private static func deprecatedNotice(_ tag: PHPDocTag) -> HoverNotice {
        let message = nonEmpty(linkifiedMarkdown(tag.content)) ?? "This symbol is deprecated."
        return HoverNotice(title: "Deprecated", message: message, tone: .warning)
    }

    private static func reference(for tag: PHPDocTag) -> HoverLink {
        let target = tag.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return HoverLink(title: target, url: safeURL(target))
    }

    private static func metadata(for docBlock: PHPDocBlock?) -> [HoverMetadataItem] {
        guard let docBlock else { return [] }

        return docBlock.tags.compactMap { tag in
            switch baseName(of: tag.name) {
            case "since":
                return HoverMetadataItem(label: "Since", value: tag.content)
            case "author":
                return HoverMetadataItem(label: "Author", value: tag.content)
            default:
                guard !isRenderedTag(tag.name) else { return nil }
                return HoverMetadataItem(label: "@\(tag.name)", value: tag.content)
            }
        }
    }

    private static func exampleBlocks(for content: String) -> [HoverBlock] {
        let content = content.trimmingCharacters(in: .newlines)
        guard !content.isEmpty else { return [] }

        if content.contains("```") {
            return [.markdown(linkifiedMarkdown(content))]
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1 {
            let firstLine = String(lines[0])
            let first = firstLine.trimmingCharacters(in: .whitespaces)
            if !first.isEmpty, firstLine == first, !looksLikeCode(first) {
                let code = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)
                var blocks: [HoverBlock] = [.markdown(linkifiedMarkdown(first))]
                if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.code(HoverCode(text: code, language: "php")))
                }
                return blocks
            }
        }

        return [.code(HoverCode(text: content, language: "php"))]
    }

    private static func looksLikeCode(_ line: String) -> Bool {
        let codeMarkers = ["$", "<?", "->", "::", "=", ";"]
        return codeMarkers.contains { line.contains($0) }
            || line.hasPrefix("#")
            || line.hasPrefix("//")
    }

}

private extension PHPHoverMapper {
    private static func containsInheritDoc(_ documentation: String?) -> Bool {
        guard let documentation else { return false }
        return documentation.range(of: "@inheritdoc", options: .caseInsensitive) != nil
            || documentation.range(of: "{@inheritdoc}", options: .caseInsensitive) != nil
    }

    private static func removingInheritMarkers(from text: String) -> String {
        guard let regex = inheritMarkerRegex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let cleaned = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func linkifiedMarkdown(_ text: String) -> String {
        guard text.contains("{@"), let regex = inlineLinkRegex else { return text }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result = text
        for match in regex.matches(in: text, range: range).reversed() {
            guard let matchRange = Range(match.range, in: result),
                  let targetRange = Range(match.range(at: 1), in: result) else { continue }
            let target = String(result[targetRange])
            guard let url = safeURL(target) else { continue }

            let label: String
            if match.range(at: 2).location != NSNotFound,
               let labelRange = Range(match.range(at: 2), in: result) {
                label = String(result[labelRange])
            } else {
                label = target
            }
            result.replaceSubrange(matchRange, with: "[\(label)](\(url.absoluteString))")
        }
        return result
    }

    private static func tags(in docBlock: PHPDocBlock?, named name: String) -> [PHPDocTag] {
        guard let docBlock else { return [] }
        return docBlock.tags.filter { baseName(of: $0.name) == name }
    }

    private static func baseName(of tagName: String) -> String {
        guard let dash = tagName.firstIndex(of: "-") else { return tagName }
        return String(tagName[tagName.index(after: dash)...])
    }

    private static func isRenderedTag(_ name: String) -> Bool {
        let rendered = [
            "param", "return", "throws", "var", "deprecated",
            "see", "example", "since", "author", "inheritdoc"
        ]
        return rendered.contains(name) || rendered.contains(baseName(of: name))
    }

    private static func safeURL(_ target: String) -> URL? {
        guard let url = URL(string: target), let scheme = url.scheme?.lowercased() else { return nil }
        return ["http", "https", "mailto"].contains(scheme) ? url : nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func systemImageName(for kind: SymbolKind) -> String {
        switch kind {
        case .class, .trait, .interface, .enum: return "cube"
        case .function, .method: return "function"
        case .property: return "square.on.square"
        case .constant: return "number"
        case .variable: return "v.square"
        case .namespace: return "folder"
        }
    }

    private static func tone(for kind: SymbolKind) -> HoverTone {
        switch kind {
        case .class, .trait, .interface, .enum: return .type
        case .function, .method: return .callable
        case .property, .variable: return .value
        case .constant, .namespace: return .namespace
        }
    }

    private static func parseSignatureParameter(_ label: String) -> SignatureParameter? {
        guard let dollar = label.firstIndex(of: "$") else { return nil }

        let variablePart = label[dollar...]
        let name = variablePart.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
        guard !name.isEmpty else { return nil }

        let prefix = label[..<dollar]
            .replacingOccurrences(of: "...", with: " ")
            .replacingOccurrences(of: "&", with: " ")
        let modifiers: Set<String> = ["public", "protected", "private", "readonly", "static", "final"]
        let type = prefix
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !modifiers.contains($0.lowercased()) }
            .joined(separator: " ")

        return SignatureParameter(name: String(name), type: nonEmpty(type))
    }

    private static let inlineLinkRegex = try? NSRegularExpression(
        pattern: #"\{@(?:link|see)\s+([^\s}]+)(?:\s+([^}]+))?\}"#,
        options: [.caseInsensitive]
    )

    private static let inheritMarkerRegex = try? NSRegularExpression(
        pattern: #"\{@inheritdoc\}"#,
        options: [.caseInsensitive]
    )

    private struct SignatureParameter {
        let name: String
        let type: String?
    }
}
