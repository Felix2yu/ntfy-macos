import Foundation

/// Stateless poll client: fetches cached history from the server via
/// `GET {topic}/json?poll=1&since=...` (NDJSON stream), decoding line by line.
enum NtfyPollClient {

    enum PollError: Error, LocalizedError {
        case http(status: Int, retryAfter: TimeInterval?)
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .http(let status, let retryAfter):
                if let retryAfter {
                    return "服务器返回 \(status)（限速），\(Int(retryAfter)) 秒后可重试"
                }
                return "服务器返回 \(status)"
            case .network(let error):
                return "网络错误：\(error.localizedDescription)"
            }
        }

        /// If this error is a rate limit (429), the suggested retry delay.
        var retryAfter: TimeInterval? {
            if case .http(429, let retryAfter) = self { return retryAfter }
            return nil
        }
    }

    struct PollResult {
        /// Number of regular message events received.
        var messageCount = 0
        /// Number of message_delete / message_clear events received.
        var actionEventCount = 0
        /// The message with the highest `time` seen (used to advance sync state).
        var newestMessage: NtfyMessage?
    }

    /// Streams the poll response, invoking `onMessage` for each regular message and
    /// `onActionEvent` for server-side delete/clear events (the fork replays those on `since`).
    static func poll(
        serverURL: String,
        topic: String,
        since: String,
        authToken: String?,
        onMessage: @escaping @Sendable (NtfyMessage) async throws -> Void,
        onActionEvent: @escaping @Sendable (NtfyMessage) async throws -> Void
    ) async throws -> PollResult {
        guard var components = URLComponents(string: serverURL) else {
            throw PollError.network(URLError(.badURL))
        }
        components.path = "/\(topic)/json"
        components.queryItems = [
            URLQueryItem(name: "poll", value: "1"),
            URLQueryItem(name: "since", value: since),
        ]
        guard let url = components.url else {
            throw PollError.network(URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        // Large full-history replays can take a while; only the time-to-first-byte is bounded.
        request.timeoutInterval = 120
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw PollError.network(error)
        }

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .map { parseRetryAfter($0) }
            throw PollError.http(status: httpResponse.statusCode, retryAfter: retryAfter)
        }

        var result = PollResult()
        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }
            let message: NtfyMessage
            do {
                message = try JSONDecoder().decode(NtfyMessage.self, from: data)
            } catch {
                Log.error("Poll: failed to decode line: \(error)")
                continue
            }

            switch message.event {
            case "message":
                result.messageCount += 1
                if message.time >= (result.newestMessage?.time ?? .min) {
                    result.newestMessage = message
                }
                try await onMessage(message)
            case NtfyMessage.deleteEvent, NtfyMessage.clearEvent:
                result.actionEventCount += 1
                try await onActionEvent(message)
            default:
                break  // open / keepalive / poll_request
            }
        }
        return result
    }

    /// Parses Retry-After (seconds or HTTP date). Mirrors NtfyClient.parseRetryAfter.
    static func parseRetryAfter(_ value: String) -> TimeInterval {
        if let seconds = TimeInterval(value) {
            return max(seconds, 1.0)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return max(date.timeIntervalSinceNow, 1.0)
            }
        }
        return 30.0
    }
}
