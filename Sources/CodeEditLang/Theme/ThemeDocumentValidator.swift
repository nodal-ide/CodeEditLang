import Foundation

public struct ThemeValidationResult: Sendable {
    public let issues: [LanguageExtensionIssue]

    public init(issues: [LanguageExtensionIssue]) {
        self.issues = issues
    }

    public var errors: [LanguageExtensionIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [LanguageExtensionIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { errors.isEmpty }
}

/// Validates `cetheme` documents. Shared by the app catalog and `codeedit-ext` so a theme is judged
/// by the same rules everywhere.
public enum ThemeDocumentValidator {
    public static let maximumFileSize = 262_144

    public static func validate(document: ThemeDocument) -> ThemeValidationResult {
        var issues: [LanguageExtensionIssue] = []

        if document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.error("`name` must not be empty.", at: "name"))
        }
        if document.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.error("`displayName` must not be empty.", at: "displayName"))
        }

        let version = document.version.trimmingCharacters(in: .whitespacesAndNewlines)
        if !version.isEmpty, SemanticVersion(version) == nil {
            issues.append(.warning("`version` is not a semantic version: \(version).", at: "version"))
        }

        let distributionURL = document.distributionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !distributionURL.isEmpty, URL(string: distributionURL) == nil {
            issues.append(.warning("`distributionURL` is not a valid URL: \(distributionURL).", at: "distributionURL"))
        }

        validateEditor(document.editor, into: &issues)
        validateTerminal(document.terminal, into: &issues)
        validateInterface(document.interface, into: &issues)

        return ThemeValidationResult(issues: issues)
    }

    public static func validate(fileAt url: URL, relativeTo basePath: String? = nil) -> ThemeValidationResult {
        let location = basePath ?? url.lastPathComponent
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return ThemeValidationResult(issues: [.error("Theme file not found: \(location)", at: location)])
        }
        if size > maximumFileSize {
            return ThemeValidationResult(issues: [
                .error("Theme file is larger than \(maximumFileSize) bytes: \(location)", at: location)
            ])
        }
        guard let data = try? Data(contentsOf: url) else {
            return ThemeValidationResult(issues: [.error("Theme file could not be read: \(location)", at: location)])
        }
        do {
            let document = try JSONDecoder().decode(ThemeDocument.self, from: data)
            let result = validate(document: document)
            guard let basePath else { return result }
            return ThemeValidationResult(
                issues: result.issues.map {
                    LanguageExtensionIssue(severity: $0.severity, message: $0.message, location: basePath)
                }
            )
        } catch {
            return ThemeValidationResult(issues: [
                .error(
                    "Theme file \(location) is invalid: \(LanguageExtensionValidator.describe(error))",
                    at: location
                )
            ])
        }
    }

    private static func validateEditor(
        _ editor: ThemeDocument.EditorColors,
        into issues: inout [LanguageExtensionIssue]
    ) {
        for key in ThemeDocument.EditorColors.keys {
            guard let attributes = editor[key] else { continue }
            validate(attributes.color, path: "editor.\(key).color", into: &issues)
        }
    }

    private static func validateTerminal(
        _ terminal: ThemeDocument.TerminalColors,
        into issues: inout [LanguageExtensionIssue]
    ) {
        for key in ThemeDocument.TerminalColors.keys {
            guard let attributes = terminal[key] else { continue }
            validate(attributes.color, path: "terminal.\(key).color", into: &issues)
        }
    }

    private static func validateInterface(
        _ interface: ThemeDocument.InterfaceColors?,
        into issues: inout [LanguageExtensionIssue]
    ) {
        guard let interface else { return }
        for key in interface.colorKeys {
            guard let color = interface[key] else { continue }
            validate(color, path: "interface.\(key)", into: &issues)
        }
    }

    private static func validate(
        _ color: String,
        path: String,
        into issues: inout [LanguageExtensionIssue]
    ) {
        if !ThemeDocument.isValidColor(color) {
            issues.append(.error("`\(path)` must be a #RRGGBB color: \(color).", at: path))
        }
    }
}
