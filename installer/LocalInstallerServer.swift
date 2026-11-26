import Foundation
import Network

final class LocalInstallerServer: @unchecked Sendable {
    enum Event: Sendable { case download, transferred }
    static let port: UInt16 = 47557

    let path: String
    private let queue = DispatchQueue(label: "org.veilgram.installer.loopback")
    private let file: URL
    private let fileSize: Int
    private let listener: NWListener
    private let onEvent: @Sendable (Event) -> Void
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var startup: CheckedContinuation<Void, Error>?

    init(file: URL, path: String, onEvent: @escaping @Sendable (Event) -> Void) throws {
        self.file = file
        self.path = path
        self.onEvent = onEvent
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw InstallerFailure.message("Подписанный IPA пуст.") }
        fileSize = size
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!
        )
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.startup = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.completeStartup()
                    case let .failed(error): self.completeStartup(error)
                    case .cancelled: self.completeStartup(CancellationError())
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.startup != nil else { return }
                    self.completeStartup(InstallerFailure.message("Не удалось открыть локальный сервер."))
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }

    private func completeStartup(_ error: Error? = nil) {
        let continuation = startup
        startup = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                if let connection { self?.finish(connection) }
            default: break
            }
        }
        connection.start(queue: queue)
        receiveHeader(connection, bytes: Data())
    }

    private func receiveHeader(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            guard error == nil else { self.finish(connection); return }
            var header = bytes
            if let data { header.append(data) }
            if header.count > 16 * 1024 {
                self.respond(connection, status: "431 Request Header Fields Too Large")
            } else if let end = header.range(of: Data([13, 10, 13, 10])) {
                if let request = String(data: header[..<end.lowerBound], encoding: .utf8) {
                    self.serve(connection, request: request)
                } else {
                    self.respond(connection, status: "400 Bad Request")
                }
            } else if complete {
                self.finish(connection)
            } else {
                self.receiveHeader(connection, bytes: header)
            }
        }
    }

    private func serve(_ connection: NWConnection, request: String) {
        let lines = request.components(separatedBy: "\r\n")
        guard let line = lines.first else { respond(connection, status: "400 Bad Request"); return }
        let requestLine = line.split(separator: " ")
        guard requestLine.count == 3, requestLine[1] == path else {
            respond(connection, status: "404 Not Found")
            return
        }
        let method = requestLine[0]
        guard method == "GET" || method == "HEAD" else {
            respond(connection, status: "405 Method Not Allowed", headers: ["Allow: GET, HEAD"])
            return
        }
        let requestedRange = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
        let range: Range<Int>
        if let requestedRange {
            guard let partial = byteRange(String(requestedRange.dropFirst(6))) else {
                respond(connection, status: "416 Range Not Satisfiable", headers: ["Content-Range: bytes */\(fileSize)"])
                return
            }
            range = partial
        } else {
            range = 0..<fileSize
        }
        var headers = ["Content-Type: application/octet-stream", "Accept-Ranges: bytes"]
        if requestedRange != nil {
            headers.append("Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(fileSize)")
        }
        let status = requestedRange == nil ? "200 OK" : "206 Partial Content"
        if method == "HEAD" {
            respond(connection, status: status, headers: headers, length: range.count)
            return
        }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            try handle.seek(toOffset: UInt64(range.lowerBound))
            onEvent(.download)
            let response = responseHeader(status, headers: headers, length: range.count)
            connection.send(content: response, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else {
                    try? handle.close()
                    connection.cancel()
                    return
                }
                self.send(connection, file: handle, remaining: range.count, reachesEnd: range.upperBound == self.fileSize)
            })
        } catch {
            respond(connection, status: "500 Internal Server Error")
        }
    }

    private func send(_ connection: NWConnection, file: FileHandle, remaining: Int, reachesEnd: Bool) {
        if remaining == 0 {
            try? file.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.finish(connection)
                if error == nil && reachesEnd { self.onEvent(.transferred) }
            })
            return
        }
        guard let bytes = try? file.read(upToCount: min(remaining, 512 * 1024)), !bytes.isEmpty else {
            try? file.close()
            finish(connection)
            return
        }
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                try? file.close()
                connection.cancel()
                return
            }
            self.send(connection, file: file, remaining: remaining - bytes.count, reachesEnd: reachesEnd)
        })
    }

    private func byteRange(_ value: String) -> Range<Int>? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("bytes="), !text.contains(",") else { return nil }
        let ends = text.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard ends.count == 2 else { return nil }
        if ends[0].isEmpty {
            guard let suffix = Int(ends[1]), suffix > 0 else { return nil }
            return max(0, fileSize - suffix)..<fileSize
        }
        guard let start = Int(ends[0]), start >= 0, start < fileSize else { return nil }
        if ends[1].isEmpty { return start..<fileSize }
        guard let end = Int(ends[1]), end >= start else { return nil }
        return start..<(min(fileSize - 1, end) + 1)
    }

    private func responseHeader(_ status: String, headers: [String], length: Int) -> Data {
        let lines = ["HTTP/1.1 \(status)", "Content-Length: \(length)", "Connection: close"] + headers
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func respond(_ connection: NWConnection, status: String, headers: [String] = [], length: Int = 0) {
        connection.send(content: responseHeader(status, headers: headers, length: length),
                        completion: .contentProcessed { [weak self] _ in self?.finish(connection) })
    }

    private func finish(_ connection: NWConnection) {
        if connections.removeValue(forKey: ObjectIdentifier(connection)) != nil {
            connection.cancel()
        }
    }
}
