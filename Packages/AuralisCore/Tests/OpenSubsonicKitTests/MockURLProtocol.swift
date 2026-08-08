import Foundation

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int?
        let headers: [String: String]
        let data: Data
        let errorCode: URLError.Code?

        static func response(
            statusCode: Int = 200,
            headers: [String: String] = ["Content-Type": "application/json"],
            data: Data
        ) -> Stub {
            Stub(statusCode: statusCode, headers: headers, data: data, errorCode: nil)
        }

        static func error(_ code: URLError.Code) -> Stub {
            Stub(statusCode: nil, headers: [:], data: Data(), errorCode: code)
        }
    }

    private static let state = State()

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var stubs: [Stub] = []
        private var capturedRequests: [URLRequest] = []

        func reset(stubs: [Stub]) {
            lock.lock()
            self.stubs = stubs
            capturedRequests = []
            lock.unlock()
        }

        func next(for request: URLRequest) -> Stub? {
            lock.lock()
            defer { lock.unlock() }
            capturedRequests.append(materialized(request))
            guard !stubs.isEmpty else { return nil }
            return stubs.removeFirst()
        }

        func requests() -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return capturedRequests
        }

        private func materialized(_ request: URLRequest) -> URLRequest {
            guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
            stream.open()
            defer { stream.close() }

            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bytes.append(buffer, count: count)
            }
            var copy = request
            copy.httpBodyStream = nil
            copy.httpBody = bytes
            return copy
        }
    }

    static func reset(stubs: [Stub]) {
        state.reset(stubs: stubs)
    }

    static var requests: [URLRequest] {
        state.requests()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.state.next(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let errorCode = stub.errorCode {
            client?.urlProtocol(self, didFailWithError: URLError(errorCode))
            return
        }
        guard
            let statusCode = stub.statusCode,
            let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

func jsonData(_ value: String) -> Data {
    Data(value.utf8)
}

func formValues(from request: URLRequest) -> [String: [String]] {
    guard let body = request.httpBody, let string = String(data: body, encoding: .utf8) else {
        return [:]
    }
    return string.split(separator: "&").reduce(into: [:]) { result, pair in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let encodedName = parts.first else { return }
        let encodedValue = parts.count == 2 ? String(parts[1]) : ""
        let name = decodeFormComponent(String(encodedName))
        result[name, default: []].append(decodeFormComponent(encodedValue))
    }
}

private func decodeFormComponent(_ value: String) -> String {
    value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
}
