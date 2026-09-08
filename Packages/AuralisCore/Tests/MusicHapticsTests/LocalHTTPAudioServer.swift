// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Network

/// A loopback HTTP server that can deliberately keep an original encoded
/// response open while sending bounded body chunks. The client therefore has
/// to prove it decodes progressively; a `data(from:)`/complete-download
/// implementation cannot pass the first-window assertion.
final class LocalHTTPAudioServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let statusCode: Int
    private let body: Data
    private let contentType: String
    private let responseChunkSize: Int
    private let responseChunkDelay: TimeInterval
    private let lock = NSLock()
    private var boundPort: UInt16 = 0
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var didResolveStart = false
    private var storedRequestCount = 0
    private var storedRangeRequests: [String] = []
    private var didSendBody = false
    private var didFinishBody = false

    init(
        statusCode: Int,
        body: Data,
        contentType: String = "audio/mpeg",
        responseChunkSize: Int? = nil,
        responseChunkDelay: TimeInterval = 0
    ) throws {
        self.statusCode = statusCode
        self.body = body
        self.contentType = contentType
        self.responseChunkSize = max(1, responseChunkSize ?? body.count)
        self.responseChunkDelay = max(0, responseChunkDelay)
        self.queue = DispatchQueue(label: "auralis.music-haptics-test-http")
        self.listener = try NWListener(using: .tcp, on: .any)
    }

    var url: URL {
        let port = lock.withLock { boundPort }
        precondition(port != 0, "LocalHTTPAudioServer must be started before accessing url")
        return URL(string: "http://127.0.0.1:\(port)/audio")!
    }

    var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    var rangeRequests: [String] {
        lock.withLock { storedRangeRequests }
    }

    /// True after the first body bytes have been handed to Network. It is
    /// intentionally separate from `bodyFinished` for progressive assertions.
    var bodyStarted: Bool {
        lock.withLock { didSendBody }
    }

    var bodyFinished: Bool {
        lock.withLock { didFinishBody }
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
                self.respond(to: connection, request: request)
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

    private func respond(to connection: NWConnection, request: Data) {
        let requestText = String(decoding: request, as: UTF8.self)
        let range = Self.rangeHeader(in: requestText)
        let responseBody: Data
        let responseStatus: Int
        let contentRange: String?
        if let range,
           statusCode == 200,
           range.lowerBound < body.count {
            let upperBound = min(body.count, range.upperBound)
            responseBody = body.subdata(in: range.lowerBound..<upperBound)
            responseStatus = 206
            contentRange = "bytes \(range.lowerBound)-\(upperBound - 1)/\(body.count)"
        } else {
            responseBody = body
            responseStatus = statusCode
            contentRange = nil
        }
        lock.withLock {
            storedRequestCount += 1
            if let range {
                let upper = range.upperBound == Int.max
                    ? ""
                    : String(range.upperBound - 1)
                storedRangeRequests.append("bytes=\(range.lowerBound)-\(upper)")
            }
            didFinishBody = false
        }
        let reason = HTTPURLResponse.localizedString(forStatusCode: responseStatus)
        var header = "HTTP/1.1 \(responseStatus) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Accept-Ranges: bytes\r\n"
            + "Content-Length: \(responseBody.count)\r\n"
        if let contentRange {
            header += "Content-Range: \(contentRange)\r\n"
        }
        header += "Connection: close\r\n\r\n"
        let headerData = Data(header.utf8)
        connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            self.sendBody(responseBody, from: 0, on: connection)
        })
    }

    private func sendBody(_ data: Data, from offset: Int, on connection: NWConnection) {
        guard offset < data.count else {
            lock.withLock { didFinishBody = true }
            connection.cancel()
            return
        }
        let end = min(data.count, offset + responseChunkSize)
        let chunk = data.subdata(in: offset..<end)
        lock.withLock { didSendBody = true }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            let sendNext: @Sendable () -> Void = {
                self.sendBody(data, from: end, on: connection)
            }
            if self.responseChunkDelay > 0 {
                self.queue.asyncAfter(
                    deadline: .now() + self.responseChunkDelay,
                    execute: sendNext
                )
            } else {
                sendNext()
            }
        })
    }

    private static func rangeHeader(in request: String) -> (lowerBound: Int, upperBound: Int)? {
        guard let line = request.components(separatedBy: .newlines).first(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("range:")
        }),
        let colon = line.firstIndex(of: ":") else {
            return nil
        }
        let value = line[line.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let range = value.dropFirst("bytes=".count)
        let pieces = range.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let lower = pieces.first.flatMap({ Int($0) }), lower >= 0 else { return nil }
        let upper: Int
        if pieces.count > 1,
           !pieces[1].isEmpty,
           let requestedUpper = Int(pieces[1]),
           requestedUpper < Int.max {
            upper = requestedUpper + 1
        } else {
            upper = Int.max
        }
        return (lower, max(lower + 1, upper))
    }

    private enum ServerError: Error {
        case cancelled
    }
}
