import Foundation

/// Errors from a programmatic language provider.
public enum ExtensionRPCError: Error, LocalizedError {
    case failedToStart(String)
    case processNotRunning
    case timeout
    case serverError(Int, String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .failedToStart(let message): return "Could not start the language provider: \(message)"
        case .processNotRunning: return "The language provider exited."
        case .timeout: return "The language provider timed out."
        case .serverError(let code, let message): return "Provider error \(code): \(message)"
        case .invalidResponse: return "The language provider returned an invalid response."
        }
    }
}

/// A JSON-RPC 2.0 client that talks to a programmatic language provider over stdin/stdout.
///
/// Language extensions run out-of-process so they can be written in any language and can't crash the
/// editor. Requests are newline-delimited JSON objects; responses carry the matching `id`.
public final class StdioLanguageServer: @unchecked Sendable {
    private let command: String
    private let args: [String]
    private let environment: [String: String]?
    private let workingDirectory: URL?
    private let requestTimeout: TimeInterval

    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextId = 1
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private var started = false

    public init(
        command: String,
        args: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        requestTimeout: TimeInterval = 5
    ) {
        self.command = command
        self.args = args
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.requestTimeout = requestTimeout
    }

    deinit {
        stop()
    }

    /// Sends a request and decodes the result into `R`. Starts the provider on first use.
    public func request<P: Encodable, R: Decodable>(_ method: String, params: P, as type: R.Type) async throws -> R {
        let result = try await send(method: method, params: params)
        guard !(result is NSNull) else {
            // Allow providers to omit a result for optional responses by decoding `null`.
            let data = Data("null".utf8)
            return try JSONDecoder().decode(R.self, from: data)
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(R.self, from: data)
    }

    /// Stops the provider process.
    public func stop() {
        lock.lock()
        let process = self.process
        self.process = nil
        self.stdinHandle = nil
        self.started = false
        let pending = self.pending
        self.pending.removeAll()
        lock.unlock()

        process?.terminate()
        for (_, continuation) in pending {
            continuation(.failure(ExtensionRPCError.processNotRunning))
        }
    }

    // MARK: - Private

    private func send<P: Encodable>(method: String, params: P) async throws -> Any {
        let paramsData = try JSONEncoder().encode(params)
        let paramsObject = try JSONSerialization.jsonObject(with: paramsData)

        try start()

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let id = nextId
            nextId += 1
            pending[id] = { continuation.resume(with: $0) }
            let request: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": paramsObject
            ]
            lock.unlock()

            guard let data = try? JSONSerialization.data(withJSONObject: request) else {
                resolve(id: id, with: .failure(ExtensionRPCError.invalidResponse))
                return
            }
            var line = data
            line.append(0x0A)

            self.lock.lock()
            let handle = self.stdinHandle
            self.lock.unlock()
            do {
                try handle?.write(contentsOf: line)
            } catch {
                resolve(id: id, with: .failure(error))
                return
            }

            // Timeout: if no response arrives, fail the request. `resolve` is idempotent.
            DispatchQueue.global().asyncAfter(deadline: .now() + self.requestTimeout) { [weak self] in
                self?.resolve(id: id, with: .failure(ExtensionRPCError.timeout))
            }
        }
    }

    private func resolve(id: Int, with result: Result<Any, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?(result)
    }

    private func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }

        let process = Process()
        process.currentDirectoryURL = workingDirectory
        if command.contains("/") {
            let url = command.hasPrefix("/")
                ? URL(fileURLWithPath: command)
                : (workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                    .appending(path: command)
            process.executableURL = url
            process.arguments = args
        } else {
            // Look the executable up on PATH.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
        }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw ExtensionRPCError.failedToStart(error.localizedDescription)
        }

        self.process = process
        self.stdinHandle = inputPipe.fileHandleForWriting
        self.started = true

        let readHandle = outputPipe.fileHandleForReading
        DispatchQueue(label: "codeedit.ext.rpc.reader").async { [weak self] in
            self?.readLoop(readHandle)
        }
    }

    private func readLoop(_ handle: FileHandle) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty {
                    handleLine(line)
                }
            }
        }
        // Process exited; fail anything outstanding.
        lock.lock()
        let pending = self.pending
        self.pending.removeAll()
        self.process = nil
        self.stdinHandle = nil
        self.started = false
        lock.unlock()
        for (_, continuation) in pending {
            continuation(.failure(ExtensionRPCError.processNotRunning))
        }
    }

    private func handleLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? Int else {
            return
        }
        if let error = object["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "error"
            resolve(id: id, with: .failure(ExtensionRPCError.serverError(code, message)))
        } else {
            resolve(id: id, with: .success(object["result"] ?? NSNull()))
        }
    }
}
