import Foundation
import CodeEditLang

func initTheme(directory: URL, name: String, identifier: String) {
    do {
        let fileManager = FileManager.default
        let themesDirectory = directory.appending(path: "themes", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: themesDirectory, withIntermediateDirectories: true)

        let themeID = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let fileName = "\(themeID).cetheme"
        let manifest = LanguageExtensionManifest(
            id: identifier,
            name: name,
            version: "0.1.0",
            type: "theme",
            description: "\(name) theme pack.",
            author: NSFullUserName(),
            capabilities: ["themes"],
            contributes: .init(themes: [.init(id: themeID, path: "themes/\(fileName)")])
        )
        try writeManifest(manifest, to: directory.appending(path: "extension.json"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sampleTheme(name: themeID, displayName: name)).write(
            to: themesDirectory.appending(path: fileName)
        )
        try themeReadme(name: name, identifier: identifier, fileName: fileName).write(
            to: directory.appending(path: "README.md"),
            atomically: true,
            encoding: .utf8
        )

        print("Created \(directory.lastPathComponent)/")
        print("  extension.json")
        print("  themes/\(fileName)")
        print("  README.md")
        print("")
        print("Next: edit the theme, then run `codeedit-ext validate \(directory.lastPathComponent)`")
        print("and `codeedit-ext pack \(directory.lastPathComponent)`.")
    } catch {
        fail("Failed to create theme extension: \(error.localizedDescription)")
    }
}

private func sampleTheme(name: String, displayName: String) -> ThemeDocument {
    func attributes(_ color: String) -> ThemeDocument.Attributes {
        .init(color: color)
    }
    let editor = ThemeDocument.EditorColors(
        text: attributes("#E6E9F2"),
        insertionPoint: attributes("#4C8DFF"),
        invisibles: attributes("#53606E"),
        background: attributes("#101418"),
        lineHighlight: attributes("#151A20"),
        selection: attributes("#2A4A7F"),
        keywords: attributes("#FF7AB2"),
        commands: attributes("#78C2B3"),
        types: attributes("#6BDFFF"),
        attributes: attributes("#CC9768"),
        variables: attributes("#4EB0CC"),
        values: attributes("#B281EB"),
        numbers: attributes("#D9C97C"),
        strings: attributes("#FF8170"),
        characters: attributes("#D9C97C"),
        comments: attributes("#7F8C98")
    )
    let terminal = ThemeDocument.TerminalColors(
        text: attributes("#E6E9F2"),
        boldText: attributes("#FFFFFF"),
        cursor: attributes("#4C8DFF"),
        background: attributes("#101418"),
        selection: attributes("#2A4A7F"),
        black: attributes("#1F2024"),
        red: attributes("#FF8170"),
        green: attributes("#78C2B3"),
        yellow: attributes("#D9C97C"),
        blue: attributes("#B281EB"),
        magenta: attributes("#FF7AB2"),
        cyan: attributes("#4EB0CC"),
        white: attributes("#D9D9D9"),
        brightBlack: attributes("#8E8E93"),
        brightRed: attributes("#FF8170"),
        brightGreen: attributes("#78C2B3"),
        brightYellow: attributes("#D9C97C"),
        brightBlue: attributes("#B281EB"),
        brightMagenta: attributes("#FF7AB2"),
        brightCyan: attributes("#4EB0CC"),
        brightWhite: attributes("#FFFFFF")
    )
    return ThemeDocument(
        name: name,
        displayName: displayName,
        metadataDescription: "\(displayName) theme.",
        author: NSFullUserName(),
        version: "0.1.0",
        appearance: .dark,
        editor: editor,
        terminal: terminal
    )
}

private func themeReadme(name: String, identifier: String, fileName: String) -> String {
    """
    # \(name)

    A CodeEdit theme extension (`\(identifier)`).

    ## Files

    - `extension.json` — the manifest (id, name, type, capabilities, contributes).
    - `themes/\(fileName)` — the theme document.

    ## Theme document

    Colors are `#RRGGBB`. The optional `interface` block overrides chrome tokens such as
    `windowBackground`, `sidebarBackground`, `accent`, `separator`, and `materials`.

    ## Validate & pack

    ```sh
    codeedit-ext validate .
    codeedit-ext pack .
    ```

    Then install the resulting `.zip` via **CodeEdit ▸ Extensions ▸ Add from Archive…**.
    """
}
