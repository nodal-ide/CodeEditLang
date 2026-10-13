import Foundation

/// An in-process, memory-bounded symbol table for a project.
///
/// Thread-safe (independent reads/lazy writes). Holds no file contents — only
/// small symbol records — and supports eviction per file so large projects stay
/// light. This is the shared index the native languages write into.
public final class SymbolIndex: @unchecked Sendable {
    /// Upper bound on the number of symbols retained (LRU-approximation by file).
    public var maxSymbols: Int

    private let lock = NSLock()
    private var byName: [String: [SymbolInfo]] = [:]
    private var byFullyQualifiedName: [String: [SymbolInfo]] = [:]
    private var byContainer: [String: [SymbolInfo]] = [:]
    private var byFile: [URL: [SymbolInfo]] = [:]
    private var symbolCount = 0
    private var accessOrder: [URL] = []

    /// Lazily-maintained sorted list of `byName` keys, for fast prefix queries.
    private var sortedNames: [String] = []
    private var namesDirty = true

    public init(maxSymbols: Int = 250_000) {
        self.maxSymbols = maxSymbols
    }

    // MARK: - Mutation

    public func add(_ symbol: SymbolInfo) {
        lock.lock()
        defer { lock.unlock() }
        addLocked(symbol)
    }

    /// Inserts many symbols under a single lock acquisition (used by bulk indexing).
    public func add(_ symbols: [SymbolInfo]) {
        lock.lock()
        defer { lock.unlock() }
        for symbol in symbols {
            addLocked(symbol)
        }
    }

    private func addLocked(_ symbol: SymbolInfo) {
        byName[symbol.name.lowercased(), default: []].append(symbol)
        byFullyQualifiedName[symbol.fullyQualifiedName.lowercased(), default: []].append(symbol)
        if let container = symbol.container, !container.isEmpty {
            byContainer[container.lowercased(), default: []].append(symbol)
        }
        byFile[symbol.fileURL, default: []].append(symbol)
        symbolCount += 1
        namesDirty = true
        touch(symbol.fileURL)

        if symbolCount > maxSymbols, let evicted = accessOrder.first {
            removeFileLocked(evicted)
        }
    }

    public func removeFile(_ file: URL) {
        lock.lock()
        defer { lock.unlock() }
        removeFileLocked(file)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        byName.removeAll()
        byFullyQualifiedName.removeAll()
        byContainer.removeAll()
        byFile.removeAll()
        accessOrder.removeAll()
        sortedNames.removeAll()
        namesDirty = true
        symbolCount = 0
    }

    // MARK: - Query

    /// All symbols whose short name equals `name` (case-insensitive).
    public func symbols(named name: String) -> [SymbolInfo] {
        lock.lock()
        defer { lock.unlock() }
        return byName[name.lowercased()] ?? []
    }

    /// All symbols whose fully-qualified name equals `name` (case-insensitive).
    public func symbols(fullyQualified name: String) -> [SymbolInfo] {
        lock.lock()
        defer { lock.unlock() }
        return byFullyQualifiedName[name.lowercased()] ?? []
    }

    /// All symbols whose short name starts with `prefix` (case-insensitive), capped at `limit`.
    ///
    /// Uses a lazily-sorted name index + binary search instead of scanning every key, so it
    /// stays fast even over the ~26k-key stub index.
    public func symbols(prefix: String, limit: Int = 200) -> [SymbolInfo] {
        lock.lock()
        defer { lock.unlock() }
        guard !prefix.isEmpty else { return [] }
        let lower = prefix.lowercased()

        if namesDirty {
            sortedNames = byName.keys.sorted()
            namesDirty = false
        }

        var result: [SymbolInfo] = []
        var index = lowerBound(of: lower)
        while index < sortedNames.count, sortedNames[index].hasPrefix(lower) {
            if let values = byName[sortedNames[index]] {
                result.append(contentsOf: values)
            }
            if result.count >= limit { break }
            index += 1
        }
        return result
    }

    /// First index in `sortedNames` whose value is `>= value`.
    private func lowerBound(of value: String) -> Int {
        var low = 0
        var high = sortedNames.count
        while low < high {
            let mid = (low + high) / 2
            if sortedNames[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    public func symbols(inFile file: URL) -> [SymbolInfo] {
        lock.lock()
        defer { lock.unlock() }
        return byFile[file] ?? []
    }

    /// Members (methods/properties/constants) declared on the given type FQN.
    public func members(ofType typeName: String) -> [SymbolInfo] {
        lock.lock()
        defer { lock.unlock() }
        guard let members = byContainer[typeName.lowercased()] else { return [] }
        return members.sorted { $0.nameRange.location < $1.nameRange.location }
    }

    // MARK: - Private

    private func touch(_ file: URL) {
        // Fast path: consecutive symbols from the same file (the common case while indexing).
        if accessOrder.last == file { return }
        accessOrder.removeAll { $0 == file }
        accessOrder.append(file)
    }

    private func removeFileLocked(_ file: URL) {
        guard let symbols = byFile.removeValue(forKey: file) else { return }
        for symbol in symbols {
            let key = symbol.name.lowercased()
            byName[key]?.removeAll { $0.fileURL == file }
            if byName[key]?.isEmpty == true { byName.removeValue(forKey: key) }

            let fqn = symbol.fullyQualifiedName.lowercased()
            byFullyQualifiedName[fqn]?.removeAll { $0.fileURL == file }
            if byFullyQualifiedName[fqn]?.isEmpty == true { byFullyQualifiedName.removeValue(forKey: fqn) }

            if let container = symbol.container?.lowercased() {
                byContainer[container]?.removeAll { $0.fileURL == file }
                if byContainer[container]?.isEmpty == true { byContainer.removeValue(forKey: container) }
            }
        }
        symbolCount -= symbols.count
        accessOrder.removeAll { $0 == file }
        namesDirty = true
    }
}