import Foundation

/// Kinds of symbols a native language produces.
public enum SymbolKind: String, Codable, Sendable {
    case `class`
    case trait
    case interface
    case `enum`
    case function
    case method
    case property
    case constant
    case variable
    case namespace
}