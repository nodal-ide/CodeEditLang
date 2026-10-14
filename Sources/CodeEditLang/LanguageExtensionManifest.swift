import Foundation

/// The `extension.json` manifest of a declarative language extension.
///
/// Required: `id` and `name`. Everything else is optional. For a pack that contributes language
/// behaviour the `languages` and `contributes` keys are expected too; `author`, `url` and `icon`
/// are display-only.
///
/// This type lives in `CodeEditLang` so both the app and the `codeedit-ext` authoring tool can
/// validate manifests with the same model.
public struct LanguageExtensionManifest: Codable {
    public var schemaVersion: Int?
    public var id: String
    public var name: String
    public var version: String?
    public var type: String?
    public var description: String?
    public var author: String?
    public var url: String?
    public var icon: String?
    public var languages: [String]?
    public var framework: String?
    public var activation: Activation?
    public var contributes: Contributes?

    public init(
        schemaVersion: Int? = 1,
        id: String,
        name: String,
        version: String? = nil,
        type: String? = "languagePack",
        description: String? = nil,
        author: String? = nil,
        url: String? = nil,
        icon: String? = nil,
        languages: [String]? = nil,
        framework: String? = nil,
        activation: Activation? = nil,
        contributes: Contributes? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.type = type
        self.description = description
        self.author = author
        self.url = url
        self.icon = icon
        self.languages = languages
        self.framework = framework
        self.activation = activation
        self.contributes = contributes
    }

    public struct Activation: Codable {
        public var files: [String]?
        public var framework: Framework?

        public init(files: [String]? = nil, framework: Framework? = nil) {
            self.files = files
            self.framework = framework
        }

        public struct Framework: Codable {
            public var file: String?
            public var requires: [String: String]?

            public init(file: String? = nil, requires: [String: String]? = nil) {
                self.file = file
                self.requires = requires
            }
        }
    }

    public struct Contributes: Codable {
        public var symbols: [String]?
        public var snippets: [String]?
        public var stubRoots: [String]?

        public init(symbols: [String]? = nil, snippets: [String]? = nil, stubRoots: [String]? = nil) {
            self.symbols = symbols
            self.snippets = snippets
            self.stubRoots = stubRoots
        }
    }

    /// The framework this pack targets — the top-level `framework`, or the first
    /// `activation.framework.requires` key.
    public var frameworkName: String? {
        if let framework, !framework.isEmpty {
            return framework
        }
        return activation?.framework?.requires?.keys.first
    }
}
