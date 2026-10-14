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
        public var provider: Provider?
        public var knowledge: [Knowledge]?

        public init(
            symbols: [String]? = nil,
            snippets: [String]? = nil,
            stubRoots: [String]? = nil,
            provider: Provider? = nil,
            knowledge: [Knowledge]? = nil
        ) {
            self.symbols = symbols
            self.snippets = snippets
            self.stubRoots = stubRoots
            self.provider = provider
            self.knowledge = knowledge
        }

        /// An offline documentation set (Markdown/HTML pages + an `index.json`).
        public struct Knowledge: Codable {
            /// Stable id for the source.
            public var id: String
            /// Display title.
            public var title: String
            /// Folder inside the pack containing the pages. Defaults to the pack root.
            public var root: String?
            /// Index file, relative to `root`. Defaults to `index.json`.
            public var index: String?

            public init(id: String, title: String, root: String? = nil, index: String? = nil) {
                self.id = id
                self.title = title
                self.root = root
                self.index = index
            }
        }

        /// A programmatic language provider, run out-of-process and spoken to over JSON-RPC on stdio.
        public struct Provider: Codable {
            /// Executable to run. A path is resolved relative to the pack root; a bare name is looked
            /// up on `PATH` (via `/usr/bin/env`).
            public var command: String
            public var args: [String]?
            public var languages: [String]?
            public var env: [String: String]?

            public init(
                command: String,
                args: [String]? = nil,
                languages: [String]? = nil,
                env: [String: String]? = nil
            ) {
                self.command = command
                self.args = args
                self.languages = languages
                self.env = env
            }
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
