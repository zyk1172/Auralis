import Foundation
import Network

/// A small loopback HTTP server for testing the same URLSession download path
/// used by remote Music Haptics sidecars. It intentionally supports only the
/// single GET/response shape needed by these tests.
final class LocalHTTPAudioServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let statusCode: Int
    private let body: Data
    private let lock = NSLock()
    private var boundPort: UInt16 = 0
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var didResolveStart = false
    private var storedRequestCount = 0

    init(statusCode: Int, body: Data) throws {
        self.statusCode = statusCode
        self.body = body
        self.queue = DispatchQueue(label: "auralis.music-haptics-test-http")
        self.listener = try NWListener(using: .tcp, on: .any)
    }

    var url: URL {
        let port = lock.withLock { boundPort }
        precondition(port != 0, "LocalHTTPAudioServer must be started before accessing url")
        return URL(string: "http://127.0.0.1:\(port)/analysis.mp3")!
    }

    var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock {
                startContinuation = continuation
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                boundPort = listener.port?.rawValue ?? 0
                guard !didResolveStart else { return nil }
                didResolveStart = true
                defer { startContinuation = nil }
                return startContinuation
            }
            continuation?.resume()
        case let .failed(error):
            resolveStart(with: error)
        case .cancelled:
            resolveStart(with: ServerError.cancelled)
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func resolveStart(with error: Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !didResolveStart else { return nil }
            didResolveStart = true
            defer { startContinuation = nil }
            return startContinuation
        }
        continuation?.resume(throwing: error)
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .ready = state {
                self.receiveRequest(on: connection)
            } else if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1024
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            var request = buffer
            if let data {
                request.append(data)
            }
            if request.range(of: Data([13, 10, 13, 10])) != nil {
                self.respond(to: connection)
            } else if let error {
                connection.cancel()
                _ = error
            } else if isComplete || request.count > 128 * 1024 {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: request)
            }
        }
    }

    private func respond(to connection: NWConnection) {
        lock.withLock {
            storedRequestCount += 1
        }
        let reason = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        let header = "HTTP/1.1 \(statusCode) \(reason)\r\n"
            + "Content-Type: audio/mpeg\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private enum ServerError: Error {
        case cancelled
    }
}
