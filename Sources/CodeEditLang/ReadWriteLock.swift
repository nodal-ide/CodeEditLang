import Darwin

/// A readers-writer lock backed by `pthread_rwlock_t`.
///
/// Allows many concurrent readers while still serializing writers — useful for the symbol
/// index, which is read constantly (completion/hover/definition) and written during indexing.
final class ReadWriteLock: @unchecked Sendable {
    private var lock = pthread_rwlock_t()

    init() {
        pthread_rwlock_init(&lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(&lock)
    }

    @inline(__always)
    func read<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return try body()
    }

    @inline(__always)
    func write<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return try body()
    }
}