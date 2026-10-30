import Foundation

/// The on-disk model of a `cetheme` file.
///
/// Lives in `CodeEditLang` so the app and the `codeedit-ext` authoring tool decode and validate the
/// same bytes with the same code. Data only: no SwiftUI or AppKit types.
public struct ThemeDocument: Codable, Hashable, Sendable {
    public enum Appearance: String, Codable, Hashable, Sendable, CaseIterable {
        case light
        case dark
    }

    public enum MaterialMode: String, Codable, Hashable, Sendable, CaseIterable {
        case system
        case solid
    }

    public var name: String
    public var displayName: String
    public var metadataDescription: String
    public var author: String
    public var license: String
    public var distributionURL: String
    public var version: String
    public var appearance: Appearance
    public var editor: EditorColors
    public var terminal: TerminalColors
    public var interface: InterfaceColors?

    public enum CodingKeys: String, CodingKey {
        case name
        case displayName
        case editor
        case terminal
        case interface
        case version
        case author
        case license
        case distributionURL
        case appearance = "type"
        case metadataDescription = "description"
    }

    public init(
        name: String,
        displayName: String,
        metadataDescription: String = "",
        author: String = "",
        license: String = "",
        distributionURL: String = "",
        version: String = "",
        appearance: Appearance,
        editor: EditorColors,
        terminal: TerminalColors,
        interface: InterfaceColors? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.metadataDescription = metadataDescription
        self.author = author
        self.license = license
        self.distributionURL = distributionURL
        self.version = version
        self.appearance = appearance
        self.editor = editor
        self.terminal = terminal
        self.interface = interface
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.metadataDescription = try container.decodeIfPresent(
            String.self, forKey: .metadataDescription
        ) ?? ""
        self.author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        self.license = try container.decodeIfPresent(String.self, forKey: .license) ?? ""
        self.distributionURL = try container.decodeIfPresent(String.self, forKey: .distributionURL) ?? ""
        self.version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        self.appearance = try container.decode(Appearance.self, forKey: .appearance)
        self.editor = try container.decode(EditorColors.self, forKey: .editor)
        self.terminal = try container.decode(TerminalColors.self, forKey: .terminal)
        self.interface = try container.decodeIfPresent(InterfaceColors.self, forKey: .interface)
    }
}

extension ThemeDocument {
    /// A single themed attribute: a `#RRGGBB` color with optional emphasis.
    public struct Attributes: Codable, Hashable, Sendable {
        public var color: String
        public var bold: Bool
        public var italic: Bool

        public init(color: String, bold: Bool = false, italic: Bool = false) {
            self.color = color
            self.bold = bold
            self.italic = italic
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.color = try container.decode(String.self, forKey: .color)
            self.bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
            self.italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(color, forKey: .color)
            if bold {
                try container.encode(bold, forKey: .bold)
            }
            if italic {
                try container.encode(italic, forKey: .italic)
            }
        }

        public enum CodingKeys: String, CodingKey {
            case color
            case bold
            case italic
        }
    }
}

extension ThemeDocument {
    /// A token as authored in a theme file: an optional `#RRGGBB` color.
    public typealias Token = String?
}

extension ThemeDocument {
    public struct InterfaceColors: Codable, Hashable, Sendable {
        public var accent: Token
        public var windowBackground: Token
        public var sidebarBackground: Token
        public var toolbarBackground: Token
        public var tabBarBackground: Token
        public var tabActiveBackground: Token
        public var tabInactiveBackground: Token
        public var panelBackground: Token
        public var overlayBackground: Token
        public var separator: Token
        public var textPrimary: Token
        public var textSecondary: Token
        public var textTertiary: Token
        public var disabledText: Token
        public var controlBackground: Token
        public var controlBorder: Token
        public var focusRing: Token
        public var selectionBackground: Token
        public var selectionForeground: Token
        public var link: Token
        public var success: Token
        public var warning: Token
        public var error: Token
        public var info: Token
        public var materials: MaterialMode?

        public init(
            accent: Token = nil,
            windowBackground: Token = nil,
            sidebarBackground: Token = nil,
            toolbarBackground: Token = nil,
            tabBarBackground: Token = nil,
            tabActiveBackground: Token = nil,
            tabInactiveBackground: Token = nil,
            panelBackground: Token = nil,
            overlayBackground: Token = nil,
            separator: Token = nil,
            textPrimary: Token = nil,
            textSecondary: Token = nil,
            textTertiary: Token = nil,
            disabledText: Token = nil,
            controlBackground: Token = nil,
            controlBorder: Token = nil,
            focusRing: Token = nil,
            selectionBackground: Token = nil,
            selectionForeground: Token = nil,
            link: Token = nil,
            success: Token = nil,
            warning: Token = nil,
            error: Token = nil,
            info: Token = nil,
            materials: MaterialMode? = nil
        ) {
            self.accent = accent
            self.windowBackground = windowBackground
            self.sidebarBackground = sidebarBackground
            self.toolbarBackground = toolbarBackground
            self.tabBarBackground = tabBarBackground
            self.tabActiveBackground = tabActiveBackground
            self.tabInactiveBackground = tabInactiveBackground
            self.panelBackground = panelBackground
            self.overlayBackground = overlayBackground
            self.separator = separator
            self.textPrimary = textPrimary
            self.textSecondary = textSecondary
            self.textTertiary = textTertiary
            self.disabledText = disabledText
            self.controlBackground = controlBackground
            self.controlBorder = controlBorder
            self.focusRing = focusRing
            self.selectionBackground = selectionBackground
            self.selectionForeground = selectionForeground
            self.link = link
            self.success = success
            self.warning = warning
            self.error = error
            self.info = info
            self.materials = materials ?? .system
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func token(_ key: CodingKeys) -> Token {
                (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
            }
            self.accent = token(.accent)
            self.windowBackground = token(.windowBackground)
            self.sidebarBackground = token(.sidebarBackground)
            self.toolbarBackground = token(.toolbarBackground)
            self.tabBarBackground = token(.tabBarBackground)
            self.tabActiveBackground = token(.tabActiveBackground)
            self.tabInactiveBackground = token(.tabInactiveBackground)
            self.panelBackground = token(.panelBackground)
            self.overlayBackground = token(.overlayBackground)
            self.separator = token(.separator)
            self.textPrimary = token(.textPrimary)
            self.textSecondary = token(.textSecondary)
            self.textTertiary = token(.textTertiary)
            self.disabledText = token(.disabledText)
            self.controlBackground = token(.controlBackground)
            self.controlBorder = token(.controlBorder)
            self.focusRing = token(.focusRing)
            self.selectionBackground = token(.selectionBackground)
            self.selectionForeground = token(.selectionForeground)
            self.link = token(.link)
            self.success = token(.success)
            self.warning = token(.warning)
            self.error = token(.error)
            self.info = token(.info)
            self.materials = ((try? container.decodeIfPresent(MaterialMode.self, forKey: .materials)) ?? nil) ?? .system
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            func encode(_ value: Token, _ key: CodingKeys) throws {
                if let value {
                    try container.encode(value, forKey: key)
                }
            }
            try encode(accent, .accent)
            try encode(windowBackground, .windowBackground)
            try encode(sidebarBackground, .sidebarBackground)
            try encode(toolbarBackground, .toolbarBackground)
            try encode(tabBarBackground, .tabBarBackground)
            try encode(tabActiveBackground, .tabActiveBackground)
            try encode(tabInactiveBackground, .tabInactiveBackground)
            try encode(panelBackground, .panelBackground)
            try encode(overlayBackground, .overlayBackground)
            try encode(separator, .separator)
            try encode(textPrimary, .textPrimary)
            try encode(textSecondary, .textSecondary)
            try encode(textTertiary, .textTertiary)
            try encode(disabledText, .disabledText)
            try encode(controlBackground, .controlBackground)
            try encode(controlBorder, .controlBorder)
            try encode(focusRing, .focusRing)
            try encode(selectionBackground, .selectionBackground)
            try encode(selectionForeground, .selectionForeground)
            try encode(link, .link)
            try encode(success, .success)
            try encode(warning, .warning)
            try encode(error, .error)
            try encode(info, .info)
            if materials != .system {
                try container.encode(materials, forKey: .materials)
            }
        }

        public enum CodingKeys: String, CodingKey {
            case accent
            case windowBackground
            case sidebarBackground
            case toolbarBackground
            case tabBarBackground
            case tabActiveBackground
            case tabInactiveBackground
            case panelBackground
            case overlayBackground
            case separator
            case textPrimary
            case textSecondary
            case textTertiary
            case disabledText
            case controlBackground
            case controlBorder
            case focusRing
            case selectionBackground
            case selectionForeground
            case link
            case success
            case warning
            case error
            case info
            case materials
        }

        /// Every key that carries a color, in a stable order.
        public var colorKeys: [String] {
            [
                "accent",
                "windowBackground",
                "sidebarBackground",
                "toolbarBackground",
                "tabBarBackground",
                "tabActiveBackground",
                "tabInactiveBackground",
                "panelBackground",
                "overlayBackground",
                "separator",
                "textPrimary",
                "textSecondary",
                "textTertiary",
                "disabledText",
                "controlBackground",
                "controlBorder",
                "focusRing",
                "selectionBackground",
                "selectionForeground",
                "link",
                "success",
                "warning",
                "error",
                "info"
            ]
        }

        public subscript(key: String) -> Token {
            switch key {
            case "accent": return accent
            case "windowBackground": return windowBackground
            case "sidebarBackground": return sidebarBackground
            case "toolbarBackground": return toolbarBackground
            case "tabBarBackground": return tabBarBackground
            case "tabActiveBackground": return tabActiveBackground
            case "tabInactiveBackground": return tabInactiveBackground
            case "panelBackground": return panelBackground
            case "overlayBackground": return overlayBackground
            case "separator": return separator
            case "textPrimary": return textPrimary
            case "textSecondary": return textSecondary
            case "textTertiary": return textTertiary
            case "disabledText": return disabledText
            case "controlBackground": return controlBackground
            case "controlBorder": return controlBorder
            case "focusRing": return focusRing
            case "selectionBackground": return selectionBackground
            case "selectionForeground": return selectionForeground
            case "link": return link
            case "success": return success
            case "warning": return warning
            case "error": return error
            case "info": return info
            default: return nil
            }
        }
    }
}

extension ThemeDocument {
    public struct EditorColors: Codable, Hashable, Sendable {
        public var text: Attributes
        public var insertionPoint: Attributes
        public var invisibles: Attributes
        public var background: Attributes
        public var lineHighlight: Attributes
        public var selection: Attributes
        public var keywords: Attributes
        public var commands: Attributes
        public var types: Attributes
        public var attributes: Attributes
        public var variables: Attributes
        public var values: Attributes
        public var numbers: Attributes
        public var strings: Attributes
        public var characters: Attributes
        public var comments: Attributes

        public init(
            text: Attributes,
            insertionPoint: Attributes,
            invisibles: Attributes,
            background: Attributes,
            lineHighlight: Attributes,
            selection: Attributes,
            keywords: Attributes,
            commands: Attributes,
            types: Attributes,
            attributes: Attributes,
            variables: Attributes,
            values: Attributes,
            numbers: Attributes,
            strings: Attributes,
            characters: Attributes,
            comments: Attributes
        ) {
            self.text = text
            self.insertionPoint = insertionPoint
            self.invisibles = invisibles
            self.background = background
            self.lineHighlight = lineHighlight
            self.selection = selection
            self.keywords = keywords
            self.commands = commands
            self.types = types
            self.attributes = attributes
            self.variables = variables
            self.values = values
            self.numbers = numbers
            self.strings = strings
            self.characters = characters
            self.comments = comments
        }

        public static let keys: [String] = [
            "text",
            "insertionPoint",
            "invisibles",
            "background",
            "lineHighlight",
            "selection",
            "keywords",
            "commands",
            "types",
            "attributes",
            "variables",
            "values",
            "numbers",
            "strings",
            "characters",
            "comments"
        ]

        public subscript(key: String) -> Attributes? {
            get {
                switch key {
                case "text": return text
                case "insertionPoint": return insertionPoint
                case "invisibles": return invisibles
                case "background": return background
                case "lineHighlight": return lineHighlight
                case "selection": return selection
                case "keywords": return keywords
                case "commands": return commands
                case "types": return types
                case "attributes": return attributes
                case "variables": return variables
                case "values": return values
                case "numbers": return numbers
                case "strings": return strings
                case "characters": return characters
                case "comments": return comments
                default: return nil
                }
            }
            set {
                guard let newValue else { return }
                switch key {
                case "text": text = newValue
                case "insertionPoint": insertionPoint = newValue
                case "invisibles": invisibles = newValue
                case "background": background = newValue
                case "lineHighlight": lineHighlight = newValue
                case "selection": selection = newValue
                case "keywords": keywords = newValue
                case "commands": commands = newValue
                case "types": types = newValue
                case "attributes": attributes = newValue
                case "variables": variables = newValue
                case "values": values = newValue
                case "numbers": numbers = newValue
                case "strings": strings = newValue
                case "characters": characters = newValue
                case "comments": comments = newValue
                default: break
                }
            }
        }
    }
}

extension ThemeDocument {
    public struct TerminalColors: Codable, Hashable, Sendable {
        public var text: Attributes
        public var boldText: Attributes
        public var cursor: Attributes
        public var background: Attributes
        public var selection: Attributes
        public var black: Attributes
        public var red: Attributes
        public var green: Attributes
        public var yellow: Attributes
        public var blue: Attributes
        public var magenta: Attributes
        public var cyan: Attributes
        public var white: Attributes
        public var brightBlack: Attributes
        public var brightRed: Attributes
        public var brightGreen: Attributes
        public var brightYellow: Attributes
        public var brightBlue: Attributes
        public var brightMagenta: Attributes
        public var brightCyan: Attributes
        public var brightWhite: Attributes

        public init(
            text: Attributes,
            boldText: Attributes,
            cursor: Attributes,
            background: Attributes,
            selection: Attributes,
            black: Attributes,
            red: Attributes,
            green: Attributes,
            yellow: Attributes,
            blue: Attributes,
            magenta: Attributes,
            cyan: Attributes,
            white: Attributes,
            brightBlack: Attributes,
            brightRed: Attributes,
            brightGreen: Attributes,
            brightYellow: Attributes,
            brightBlue: Attributes,
            brightMagenta: Attributes,
            brightCyan: Attributes,
            brightWhite: Attributes
        ) {
            self.text = text
            self.boldText = boldText
            self.cursor = cursor
            self.background = background
            self.selection = selection
            self.black = black
            self.red = red
            self.green = green
            self.yellow = yellow
            self.blue = blue
            self.magenta = magenta
            self.cyan = cyan
            self.white = white
            self.brightBlack = brightBlack
            self.brightRed = brightRed
            self.brightGreen = brightGreen
            self.brightYellow = brightYellow
            self.brightBlue = brightBlue
            self.brightMagenta = brightMagenta
            self.brightCyan = brightCyan
            self.brightWhite = brightWhite
        }

        public static let keys: [String] = [
            "text",
            "boldText",
            "cursor",
            "background",
            "selection",
            "black",
            "red",
            "green",
            "yellow",
            "blue",
            "magenta",
            "cyan",
            "white",
            "brightBlack",
            "brightRed",
            "brightGreen",
            "brightYellow",
            "brightBlue",
            "brightMagenta",
            "brightCyan",
            "brightWhite"
        ]

        public var ansiColors: [String] {
            [
                black.color,
                red.color,
                green.color,
                yellow.color,
                blue.color,
                magenta.color,
                cyan.color,
                white.color,
                brightBlack.color,
                brightRed.color,
                brightGreen.color,
                brightYellow.color,
                brightBlue.color,
                brightMagenta.color,
                brightCyan.color,
                brightWhite.color
            ]
        }

        public subscript(key: String) -> Attributes? {
            get {
                switch key {
                case "text": return text
                case "boldText": return boldText
                case "cursor": return cursor
                case "background": return background
                case "selection": return selection
                case "black": return black
                case "red": return red
                case "green": return green
                case "yellow": return yellow
                case "blue": return blue
                case "magenta": return magenta
                case "cyan": return cyan
                case "white": return white
                case "brightBlack": return brightBlack
                case "brightRed": return brightRed
                case "brightGreen": return brightGreen
                case "brightYellow": return brightYellow
                case "brightBlue": return brightBlue
                case "brightMagenta": return brightMagenta
                case "brightCyan": return brightCyan
                case "brightWhite": return brightWhite
                default: return nil
                }
            }
            set {
                guard let newValue else { return }
                switch key {
                case "text": text = newValue
                case "boldText": boldText = newValue
                case "cursor": cursor = newValue
                case "background": background = newValue
                case "selection": selection = newValue
                case "black": black = newValue
                case "red": red = newValue
                case "green": green = newValue
                case "yellow": yellow = newValue
                case "blue": blue = newValue
                case "magenta": magenta = newValue
                case "cyan": cyan = newValue
                case "white": white = newValue
                case "brightBlack": brightBlack = newValue
                case "brightRed": brightRed = newValue
                case "brightGreen": brightGreen = newValue
                case "brightYellow": brightYellow = newValue
                case "brightBlue": brightBlue = newValue
                case "brightMagenta": brightMagenta = newValue
                case "brightCyan": brightCyan = newValue
                case "brightWhite": brightWhite = newValue
                default: break
                }
            }
        }
    }
}

extension ThemeDocument {
    /// Whether `value` is a `#RRGGBB` color the host can render.
    public static func isValidColor(_ value: String) -> Bool {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6 else { return false }
        return hex.allSatisfy { $0.isHexDigit }
    }
}
