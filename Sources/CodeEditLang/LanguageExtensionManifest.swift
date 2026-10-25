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
    public var engines: Engines?
    public var capabilities: [String]?
    public var activation: Activation?
    public var contributes: Contributes?

    public init(
        schemaVersion: Int? = 2,
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
        engines: Engines? = nil,
        capabilities: [String]? = nil,
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
        self.engines = engines
        self.capabilities = capabilities
        self.activation = activation
        self.contributes = contributes
    }

    /// Host-version requirements for this pack.
    public struct Engines: Codable {
        /// A semver-style requirement such as `>=0.18.0` or `^0.18.0`.
        public var codeedit: String?

        public init(codeedit: String? = nil) {
            self.codeedit = codeedit
        }
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
        public var syntax: [Syntax]?
        public var symbols: [String]?
        public var snippets: [String]?
        public var stubRoots: [String]?
        public var provider: Provider?
        public var knowledge: [Knowledge]?

        public init(
            syntax: [Syntax]? = nil,
            symbols: [String]? = nil,
            snippets: [String]? = nil,
            stubRoots: [String]? = nil,
            provider: Provider? = nil,
            knowledge: [Knowledge]? = nil
        ) {
            self.syntax = syntax
            self.symbols = symbols
            self.snippets = snippets
            self.stubRoots = stubRoots
            self.provider = provider
            self.knowledge = knowledge
        }

        /// A declarative syntax contribution: queries plus either a built-in grammar reference or a
        /// native grammar dylib shipped in the pack.
        public struct Syntax: Codable {
            /// The document language identifier.
            public var id: String
            public var displayName: String?
            public var extensions: [String]?
            public var filenames: [String]?
            public var shebangs: [String]?
            public var firstLinePatterns: [String]?
            public var grammar: Grammar
            public var queries: Queries
            public var aliases: [String]?
            public var comments: Comments?

            public init(
                id: String,
                displayName: String? = nil,
                extensions: [String]? = nil,
                filenames: [String]? = nil,
                shebangs: [String]? = nil,
                firstLinePatterns: [String]? = nil,
                grammar: Grammar,
                queries: Queries,
                aliases: [String]? = nil,
                comments: Comments? = nil
            ) {
                self.id = id
                self.displayName = displayName
                self.extensions = extensions
                self.filenames = filenames
                self.shebangs = shebangs
                self.firstLinePatterns = firstLinePatterns
                self.grammar = grammar
                self.queries = queries
                self.aliases = aliases
                self.comments = comments
            }

            public struct Comments: Codable {
                public var line: String?
                public var block: [String]?

                public init(line: String? = nil, block: [String]? = nil) {
                    self.line = line
                    self.block = block
                }
            }

            public struct Grammar: Codable {
                public var kind: String
                /// Built-in grammar name, for example `json` or `html`.
                public var name: String?
                /// Native grammar path, relative to the pack root.
                public var path: String?
                /// Exported `tree_sitter_*` symbol of the native grammar.
                public var symbol: String?
                /// Lowercase hex SHA-256 of the native grammar binary, when the author pins one.
                public var sha256: String?

                public init(
                    kind: String,
                    name: String? = nil,
                    path: String? = nil,
                    symbol: String? = nil,
                    sha256: String? = nil
                ) {
                    self.kind = kind
                    self.name = name
                    self.path = path
                    self.symbol = symbol
                    self.sha256 = sha256
                }
            }

            public struct Queries: Codable {
                public var highlights: String
                public var injections: String?
                public var folds: String?
                public var indents: String?
                public var locals: String?
                public var tags: String?
                public var parent: String?

                public init(
                    highlights: String,
                    injections: String? = nil,
                    folds: String? = nil,
                    indents: String? = nil,
                    locals: String? = nil,
                    tags: String? = nil,
                    parent: String? = nil
                ) {
                    self.highlights = highlights
                    self.injections = injections
                    self.folds = folds
                    self.indents = indents
                    self.locals = locals
                    self.tags = tags
                    self.parent = parent
                }

                public var allPaths: [String] {
                    [
                        highlights, injections, folds, indents, locals, tags, parent
                    ].compactMap { $0 }
                }

                /// The declared query files paired with their query name, in a deterministic order.
                public var namedPaths: [(name: String, path: String)] {
                    var result: [(name: String, path: String)] = [("highlights", highlights)]
                    if let injections { result.append(("injections", injections)) }
                    if let folds { result.append(("folds", folds)) }
                    if let indents { result.append(("indents", indents)) }
                    if let locals { result.append(("locals", locals)) }
                    if let tags { result.append(("tags", tags)) }
                    if let parent { result.append(("parent", parent)) }
                    return result
                }
            }
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
            /// Single-character triggers that open the completion window for this provider.
            /// `nil` preserves the host's legacy PHP-oriented trigger set.
            public var completionTriggers: [String]?

            public init(
                command: String,
                args: [String]? = nil,
                languages: [String]? = nil,
                env: [String: String]? = nil,
                completionTriggers: [String]? = nil
            ) {
                self.command = command
                self.args = args
                self.languages = languages
                self.env = env
                self.completionTriggers = completionTriggers
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
