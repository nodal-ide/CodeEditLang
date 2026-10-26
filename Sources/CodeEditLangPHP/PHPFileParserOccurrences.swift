import Foundation
import CodeEditLang

/// Extracts the name occurrences a scanned PHP file contributes to reference matching.
///
/// Kept as a separate pure type so the reference engine can test touchdown without reaching
/// into the scanner, and so repeated occurrences for the same file can be cached if needed
/// later without changing the engine.
enum PHPFileParserOccurrences {

    /// All name occurrences in `info` that matter for find-references.
    static func from(info: PHPFileSymbols, source: NSString, fileURL: URL, offset: Int = 0) -> [PHPReferenceOccurrence] {
        var out: [PHPReferenceOccurrence] = []
        out.reserveCapacity(info.classReferences.count + info.functionCalls.count + info.thisMethodCalls.count + info.referenceNames.count)

        for ref in info.classReferences {
            out.append(PHPReferenceOccurrence(
                name: ref.name,
                range: ref.range,
                fileURL: fileURL,
                isTypeReference: true,
                isFunctionCall: false,
                isMemberCall: false,
                receiverType: nil,
                containerFQN: info.classContaining(offset: ref.range.location)
            ))
        }

        for call in info.functionCalls {
            out.append(PHPReferenceOccurrence(
                name: call.name,
                range: call.range,
                fileURL: fileURL,
                isTypeReference: false,
                isFunctionCall: true,
                isMemberCall: false,
                receiverType: nil,
                containerFQN: info.classContaining(offset: call.range.location)
            ))
        }

        for method in info.thisMethodCalls {
            out.append(PHPReferenceOccurrence(
                name: method.name,
                range: method.range,
                fileURL: fileURL,
                isTypeReference: false,
                isFunctionCall: false,
                isMemberCall: true,
                receiverType: nil,
                containerFQN: info.classContaining(offset: method.range.location)
            ))
        }

        // Other referenced names that were not already captured as calls/refs — these are
        // name-only references (e.g. bare qualified names in expressions) and are treated
        // as heuristic only when they match the target short name.
        let captured = Set(info.classReferences.map { $0.name.lowercased() })
            .union(Set(info.functionCalls.map { $0.name.lowercased() }))
            .union(Set(info.thisMethodCalls.map { $0.name.lowercased() }))
        for name in info.referenceNames where !captured.contains(name.lowercased()) {
            let range = source.range(of: name)
            out.append(PHPReferenceOccurrence(
                name: name,
                range: range,
                fileURL: fileURL,
                isTypeReference: false,
                isFunctionCall: false,
                isMemberCall: false,
                receiverType: nil,
                containerFQN: info.classContaining(offset: range.location)
            ))
        }

        return out
    }
}
