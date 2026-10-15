import Foundation

/// Downloads a body in the chunks URLSession delivers (an `AsyncBytes` loop costs one async step per
/// byte: about a minute for 10 MB), stops once it passes `maxBytes`, and refuses a redirect from
/// https to http.
enum BoundedFetch {
    struct TooLarge: Error {}

    static func data(for request: URLRequest, route: FetchRoute, timeout: TimeInterval, maxBytes: Int,
                     onProgress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        let collector = Collector(maxBytes: maxBytes, onProgress: onProgress)
        let session = SessionFactory.make(route: route, timeout: timeout, delegate: collector)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func allowsRedirect(from: URL?, to: URL?) -> Bool {
        from?.scheme?.lowercased() != "https" || to?.scheme?.lowercased() == "https"
    }

    /// Callbacks arrive one at a time on the session's serial delegate queue, and `continuation`
    /// is set before the task starts.
    private final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let maxBytes: Int
        let onProgress: (@Sendable (DownloadProgress) -> Void)?
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var body = Data()
        private var total: Int64?
        private var failure: Error?
        private var lastReport = ContinuousClock.now

        init(maxBytes: Int, onProgress: (@Sendable (DownloadProgress) -> Void)?) {
            self.maxBytes = maxBytes
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard BoundedFetch.allowsRedirect(from: response.url, to: request.url) else {
                failure = URLError(.appTransportSecurityRequiresSecureConnection)
                task.cancel()
                return completionHandler(nil)
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            if response.expectedContentLength > Int64(maxBytes) {
                failure = TooLarge()
                return completionHandler(.cancel)
            }
            total = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            onProgress?(DownloadProgress(received: 0, total: total))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            body.append(data)
            if body.count > maxBytes {
                failure = TooLarge()
                return dataTask.cancel()
            }
            if let onProgress, ContinuousClock.now - lastReport >= .milliseconds(100) {
                lastReport = .now
                onProgress(DownloadProgress(received: Int64(body.count), total: total))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let continuation else { return }
            self.continuation = nil
            if let error = failure ?? error { return continuation.resume(throwing: error) }
            guard let http = task.response as? HTTPURLResponse else {
                return continuation.resume(throwing: URLError(.badServerResponse))
            }
            onProgress?(DownloadProgress(received: Int64(body.count), total: total))
            continuation.resume(returning: (body, http))
        }
    }
}
