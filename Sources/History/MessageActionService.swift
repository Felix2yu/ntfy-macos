import Foundation
import AppKit

/// Server-side message operations (delete, mark-read) plus shared URL-opening helpers.
enum MessageActionService {

    /// Requests the server to delete a cached message:
    /// `DELETE {server}/{topic}/{sequence_id}` (fork supports it; upstream >= v2.16).
    /// Any failure is logged and silently ignored — the local tombstone stays in place.
    static func deleteOnServer(
        serverURL: String,
        topic: String,
        sequenceID: String?,
        messageID: String,
        authToken: String?
    ) async {
        // Prefer sequence_id; fall back to the plain message id (also accepted by the fork).
        let targetID = sequenceID ?? messageID
        guard !targetID.isEmpty else { return }

        guard let url = URL(string: "\(serverURL)/\(topic)/\(targetID)") else {
            Log.error("Server delete: invalid URL for \(topic)/\(targetID)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200...299:
                    Log.info("Server delete ok: \(topic)/\(targetID)")
                case 404:
                    // Already gone server-side — fine.
                    Log.info("Server delete: \(topic)/\(targetID) not found (already gone)")
                default:
                    Log.error("Server delete failed for \(topic)/\(targetID): HTTP \(httpResponse.statusCode)")
                }
            }
        } catch {
            Log.error("Server delete failed for \(topic)/\(targetID): \(error.localizedDescription)")
        }
    }

    /// Requests the server to mark a cached message as read:
    /// `GET {server}/{topic}/{sequence_id}/read` (alias of `/clear`). The server turns this
    /// into a `message_clear` broadcast, so every other device follows along.
    /// Failures are logged and reported through the return value — the local read state is
    /// already applied, so an offline or read-only client simply stays local.
    /// - Returns: true when the server accepted the event (or the target is already gone).
    @discardableResult
    static func markReadOnServer(
        serverURL: String,
        topic: String,
        sequenceID: String?,
        messageID: String,
        authToken: String?,
        session: URLSession = .shared
    ) async -> Bool {
        let targetID = sequenceID ?? messageID
        guard !targetID.isEmpty else { return false }

        guard let url = URL(string: "\(serverURL)/\(topic)/\(targetID)/read") else {
            Log.error("Server mark-read: invalid URL for \(topic)/\(targetID)")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                Log.error("Server mark-read failed for \(topic)/\(targetID): no HTTP response")
                return false
            }
            switch httpResponse.statusCode {
            case 200...299, 404:
                // 404: target already gone server-side, which is the state we wanted anyway.
                Log.info("Server mark-read ok: \(topic)/\(targetID) (HTTP \(httpResponse.statusCode))")
                return true
            default:
                Log.error("Server mark-read failed for \(topic)/\(targetID): HTTP \(httpResponse.statusCode)")
                return false
            }
        } catch {
            Log.error("Server mark-read failed for \(topic)/\(targetID): \(error.localizedDescription)")
            return false
        }
    }

    /// Marks a batch of messages read on the server, one request each. Stops at the first
    /// rejection: that usually means offline or no write permission, and every request
    /// publishes a message against the server's per-visitor rate limit.
    /// - Returns: how many targets the server accepted.
    @discardableResult
    static func markAllReadOnServer(
        serverURL: String,
        topic: String,
        targets: [(sequenceID: String?, messageID: String)],
        authToken: String?,
        session: URLSession = .shared
    ) async -> Int {
        var synced = 0
        for target in targets {
            let ok = await markReadOnServer(
                serverURL: serverURL, topic: topic,
                sequenceID: target.sequenceID, messageID: target.messageID,
                authToken: authToken, session: session
            )
            guard ok else {
                Log.info("Server mark-all-read for \(topic) stopped after \(synced)/\(targets.count)")
                return synced
            }
            synced += 1
        }
        return synced
    }


    // MARK: - Message actions (view / http / copy)

    /// Executes an ntfy message action from the history UI.
    /// - Parameter serverURL: base URL of the server the message came from — allow-lists
    ///   are configured per server, and the same topic name can exist on several.
    static func execute(action: NtfyMessage.NtfyAction, serverURL: String) {
        switch action.action {
        case "view":
            guard let urlString = action.url, let url = URL(string: urlString) else { return }
            openSecurely(url, serverBaseURL: serverURL)
        case "http":
            guard let urlString = action.url, let url = URL(string: urlString) else { return }
            executeHTTP(url: url, method: action.method ?? "POST", headers: action.headers, body: action.body)
        case "copy":
            let text = action.body ?? action.url ?? ""
            if !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default:
            // "broadcast" is Android-only; script actions are config-only by design.
            Log.info("Unsupported action type '\(action.action)' in history UI")
        }
    }

    /// Opens a URL after validating scheme/domain against the server config —
    /// same rules as NotificationManager.openUrlSecurely.
    static func openSecurely(_ url: URL, serverBaseURL: String?) {
        let serverConfig = serverBaseURL.flatMap { ConfigManager.shared.config?.server(forURL: $0) }

        let schemeAllowed = serverConfig?.isSchemeAllowed(url) ?? ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        guard schemeAllowed else {
            let allowed = serverConfig?.effectiveAllowedSchemes ?? ["http", "https"]
            Log.info("Refusing to open URL with untrusted scheme: \(url.scheme ?? "nil") (\(url.absoluteString)). Allowed: \(allowed)")
            return
        }

        guard serverConfig?.isDomainAllowed(url) ?? true else {
            let allowed = serverConfig?.allowedDomains ?? []
            Log.info("Refusing to open URL with untrusted domain: \(url.host ?? "nil") (\(url.absoluteString)). Allowed: \(allowed)")
            return
        }

        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    private static func executeHTTP(url: URL, method: String, headers: [String: String]?, body: String?) {
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.httpBody = body.data(using: .utf8)
        }
        Log.info("Executing HTTP \(method) action: \(url.absoluteString)")

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                Log.error("HTTP action failed: \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse {
                Log.info("HTTP action completed with status: \(httpResponse.statusCode)")
            }
        }.resume()
    }

    // MARK: - Formatting helpers

    /// Human-readable timestamp: relative time for recent messages, absolute date otherwise.
    static func formattedTime(_ unixSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "刚刚"
        } else if interval < 24 * 3600 {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        } else if interval < 365 * 24 * 3600 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 HH:mm"
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy年M月d日"
            return formatter.string(from: date)
        }
    }

    /// Human-readable file size.
    static func formattedFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
