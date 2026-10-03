import Foundation
import Yams

struct NotificationAction: Codable {
    var title: String
    var type: String      // "script", "view", "shortcut", or "applescript"
    var path: String?     // for scripts and applescript files
    var url: String?      // for view actions
    var name: String?     // for shortcuts (the shortcut name)
    var script: String?   // for inline applescript

    init(title: String, type: String, path: String? = nil, url: String? = nil, name: String? = nil, script: String? = nil) {
        self.title = title
        self.type = type
        self.path = path
        self.url = url
        self.name = name
        self.script = script
    }
}

struct TopicConfig: Codable {
    let name: String
    let iconPath: String?
    let iconSymbol: String?
    let autoRunScript: String?
    let silent: Bool?
    let clickUrl: ClickUrlConfig?  // Control click behavior: true/false/custom URL
    let actions: [NotificationAction]?
    let fetchMissed: Bool?

    init(name: String, iconPath: String? = nil, iconSymbol: String? = nil, autoRunScript: String? = nil, silent: Bool? = nil, clickUrl: ClickUrlConfig? = nil, actions: [NotificationAction]? = nil, fetchMissed: Bool? = nil) {
        self.name = name
        self.iconPath = iconPath
        self.iconSymbol = iconSymbol
        self.autoRunScript = autoRunScript
        self.silent = silent
        self.clickUrl = clickUrl
        self.actions = actions
        self.fetchMissed = fetchMissed
    }

    enum CodingKeys: String, CodingKey {
        case name
        case iconPath = "icon_path"
        case iconSymbol = "icon_symbol"
        case autoRunScript = "auto_run_script"
        case silent
        case clickUrl = "click_url"
        case actions
        case fetchMissed = "fetch_missed"
    }

    /// Whether to fetch missed messages for this topic (default: false)
    var shouldFetchMissed: Bool {
        fetchMissed ?? false
    }
}

/// Represents click_url config: can be a URL string, true (use default), or false (disabled)
enum ClickUrlConfig: Codable, Equatable {
    case enabled          // true or not specified: use webUrl or url
    case disabled         // false: don't open anything on click
    case custom(String)   // custom URL

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolValue = try? container.decode(Bool.self) {
            self = boolValue ? .enabled : .disabled
        } else if let stringValue = try? container.decode(String.self) {
            self = .custom(stringValue)
        } else {
            self = .enabled
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .enabled:
            try container.encode(true)
        case .disabled:
            try container.encode(false)
        case .custom(let url):
            try container.encode(url)
        }
    }
}

struct ServerConfig: Codable {
    let url: String
    let token: String?
    let topics: [TopicConfig]
    let allowedSchemes: [String]?
    let allowedDomains: [String]?
    let fetchMissed: Bool?

    init(url: String, token: String? = nil, topics: [TopicConfig], allowedSchemes: [String]? = nil, allowedDomains: [String]? = nil, fetchMissed: Bool? = nil) {
        self.url = url
        self.token = token
        self.topics = topics
        self.allowedSchemes = allowedSchemes
        self.allowedDomains = allowedDomains
        self.fetchMissed = fetchMissed
    }

    enum CodingKeys: String, CodingKey {
        case url
        case token
        case topics
        case allowedSchemes = "allowed_schemes"
        case allowedDomains = "allowed_domains"
        case fetchMissed = "fetch_missed"
    }

    /// Whether to fetch missed messages on reconnect (default: false)
    var shouldFetchMissed: Bool {
        fetchMissed ?? false
    }

    /// Returns the list of allowed URL schemes, defaulting to ["http", "https"]
    var effectiveAllowedSchemes: [String] {
        allowedSchemes ?? ["http", "https"]
    }

    /// Validates if a URL's scheme is allowed for this server
    func isSchemeAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return effectiveAllowedSchemes.map { $0.lowercased() }.contains(scheme)
    }

    /// Validates if a URL's domain is allowed for this server (nil means all domains allowed, empty array means none allowed)
    func isDomainAllowed(_ url: URL) -> Bool {
        guard let allowedDomains = allowedDomains else {
            return true  // No restriction if not configured (nil)
        }
        guard !allowedDomains.isEmpty else {
            return false  // Empty array means no domains allowed
        }
        guard let host = url.host?.lowercased() else { return false }
        return allowedDomains.map { $0.lowercased() }.contains { allowedDomain in
            // Support wildcard subdomains: "*.example.com" matches "sub.example.com"
            if allowedDomain.hasPrefix("*.") {
                let baseDomain = String(allowedDomain.dropFirst(2))
                return host == baseDomain || host.hasSuffix("." + baseDomain)
            }
            return host == allowedDomain
        }
    }

    /// Validates if a URL is allowed (both scheme and domain)
    func isUrlAllowed(_ url: URL) -> Bool {
        return isSchemeAllowed(url) && isDomainAllowed(url)
    }
}

struct AppConfig: Codable {
    let servers: [ServerConfig]
    let localServerPort: UInt16?

    init(servers: [ServerConfig], localServerPort: UInt16? = nil) {
        self.servers = servers
        self.localServerPort = localServerPort
    }

    enum CodingKeys: String, CodingKey {
        case servers
        case localServerPort = "local_server_port"
    }

    // Convenience: all topics across all servers
    var allTopics: [TopicConfig] {
        servers.flatMap { $0.topics }
    }

    /// Finds the server config by its base URL. Topic behaviour must be resolved per
    /// (server, topic) — the same topic name on different servers has different config.
    func server(forURL url: String) -> ServerConfig? {
        servers.first { $0.url == url }
    }

    /// Finds a topic's configuration within one specific server.
    func topicConfig(serverURL: String, topic topicName: String) -> TopicConfig? {
        server(forURL: serverURL)?.topics.first { $0.name == topicName }
    }

    /// Every currently subscribed (server, topic) pair; anything in the history
    /// database outside this set is an orphan left by a deleted subscription.
    var subscriptions: Set<TopicRef> {
        Set(servers.flatMap { server in
            server.topics.map { TopicRef(serverURL: server.url, topic: $0.name) }
        })
    }
}

enum ConfigError: Error, LocalizedError {
    case fileNotFound
    case invalidYAML(Error)
    case decodingError(Error)
    case insecureFilePermissions(String)
    case unknownKeys(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "未找到配置文件"
        case .invalidYAML(let error):
            return "YAML 无效：\(error.localizedDescription)"
        case .decodingError(let error):
            return "配置错误：\(error.localizedDescription)"
        case .insecureFilePermissions(let message):
            return message
        case .unknownKeys(let details):
            return "未知配置项：\n\(details)"
        }
    }
}

/// Validates configuration before use
struct ConfigValidator {
    
    /// Validates the entire config
    static func validate(_ config: AppConfig) throws {
        // Validate servers
        for server in config.servers {
            try validateServerURL(server.url)
            
            // Validate topics
            guard !server.topics.isEmpty else {
                throw ConfigError.decodingError(NSError(
                    domain: "ConfigValidator",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "服务器 \(server.url) 未配置任何主题"]
                ))
            }
            
            // Validate unique topic names per server
            let topicNames = server.topics.map { $0.name }
            if topicNames.count != Set(topicNames).count {
                throw ConfigError.decodingError(NSError(
                    domain: "ConfigValidator",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "服务器 \(server.url) 中存在重复的主题名称"]
                ))
            }
        }
    }
    
    /// Validates a server URL
    static func validateServerURL(_ urlString: String) throws {
        guard let url = URL(string: urlString) else {
            throw ConfigError.decodingError(NSError(
                domain: "ConfigValidator",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "URL 格式无效：\(urlString)"]
            ))
        }
        
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ConfigError.decodingError(NSError(
                domain: "ConfigValidator",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "URL 必须使用 http 或 https 协议：\(urlString)"]
            ))
        }
        
        guard url.host != nil && !url.host!.isEmpty else {
            throw ConfigError.decodingError(NSError(
                domain: "ConfigValidator",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "URL 必须包含有效主机名：\(urlString)"]
            ))
        }
    }
}

final class ConfigManager: @unchecked Sendable {
    static let shared = ConfigManager()
    private let lock = NSLock()
    private var _config: AppConfig?
    private var _activePath: String?

    var config: AppConfig? {
        lock.lock()
        defer { lock.unlock() }
        return _config
    }

    /// The file this process loaded (and therefore saves/reloads), set by `loadConfig`.
    /// Without it a `serve --config` instance would silently fall back to the default
    /// path on watcher reloads and Settings saves.
    var activePath: String? {
        lock.lock()
        defer { lock.unlock() }
        return _activePath
    }

    private init() {}

    /// Default configuration path: ~/.config/ntfyx/config.yml
    static var defaultConfigPath: String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".config/ntfyx/config.yml").path
    }

    /// Loads configuration from the specified path or default location
    func loadConfig(from path: String? = nil) throws {
        let configPath = path ?? activePath ?? ConfigManager.defaultConfigPath
        let url = URL(fileURLWithPath: configPath)

        guard FileManager.default.fileExists(atPath: configPath) else {
            throw ConfigError.fileNotFound
        }

        // Validate file permissions - should not be world-writable
        try validateFilePermissions(at: configPath)

        let yamlString: String
        do {
            yamlString = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigError.fileNotFound
        }

        // Validate for unknown keys before decoding (warnings only, doesn't block loading)
        let unknownKeysWarning = checkForUnknownKeys(in: yamlString)

        let decoder = YAMLDecoder()
        do {
            let decodedConfig = try decoder.decode(AppConfig.self, from: yamlString)
            lock.lock()
            defer { lock.unlock() }
            self._config = decodedConfig
            self._configWarning = unknownKeysWarning
            self._activePath = configPath
        } catch {
            throw ConfigError.decodingError(error)
        }
    }

    /// Warning message for unknown keys (doesn't prevent loading)
    private var _configWarning: String?
    var configWarning: String? {
        lock.lock()
        defer { lock.unlock() }
        return _configWarning
    }

    /// Known keys at each level of the config
    private static let knownRootKeys: Set<String> = ["servers", "local_server_port"]
    private static let knownServerKeys: Set<String> = ["url", "token", "topics", "allowed_schemes", "allowed_domains", "fetch_missed"]
    private static let knownTopicKeys: Set<String> = ["name", "icon_path", "icon_symbol", "auto_run_script", "silent", "click_url", "actions", "fetch_missed"]
    private static let knownActionKeys: Set<String> = ["title", "type", "path", "url", "name", "script"]

    /// Checks YAML for unknown keys that would be silently ignored
    /// Returns warning message if unknown keys found, nil otherwise
    private func checkForUnknownKeys(in yamlString: String) -> String? {
        guard let yaml = try? Yams.load(yaml: yamlString) as? [String: Any] else {
            return nil  // Let the decoder handle invalid YAML
        }

        var warnings: [String] = []

        // Check root level
        for key in yaml.keys {
            if !Self.knownRootKeys.contains(key) {
                warnings.append("根级别存在未知配置项 '\(key)'")
            }
        }

        // Check servers
        if let servers = yaml["servers"] as? [[String: Any]] {
            for (serverIndex, server) in servers.enumerated() {
                let serverUrl = server["url"] as? String ?? "server[\(serverIndex)]"
                for key in server.keys {
                    if !Self.knownServerKeys.contains(key) {
                        warnings.append("服务器 '\(serverUrl)' 中存在未知配置项 '\(key)'")
                    }
                }

                // Check topics
                if let topics = server["topics"] as? [[String: Any]] {
                    for (topicIndex, topic) in topics.enumerated() {
                        let topicName = topic["name"] as? String ?? "topic[\(topicIndex)]"
                        for key in topic.keys {
                            if !Self.knownTopicKeys.contains(key) {
                                warnings.append("主题 '\(topicName)'（服务器：\(serverUrl)）中存在未知配置项 '\(key)'")
                            }
                        }

                        // Check actions
                        if let actions = topic["actions"] as? [[String: Any]] {
                            for (actionIndex, action) in actions.enumerated() {
                                let actionTitle = action["title"] as? String ?? "action[\(actionIndex)]"
                                for key in action.keys {
                                    if !Self.knownActionKeys.contains(key) {
                                        warnings.append("动作 '\(actionTitle)'（主题：\(topicName)）中存在未知配置项 '\(key)'")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if warnings.isEmpty {
            return nil
        }
        return warnings.joined(separator: "\n")
    }

    /// Validates that the config file has secure permissions (not world-writable)
    private func validateFilePermissions(at path: String) throws {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: path)

        guard let posixPermissions = attributes[.posixPermissions] as? Int else {
            return  // Can't determine permissions, allow
        }

        // Check if world-writable (others have write permission: ----w--w-)
        // POSIX permission bits: owner (rwx), group (rwx), others (rwx)
        // World-writable means the last octet has write bit (0o002)
        let worldWritable = (posixPermissions & 0o002) != 0

        if worldWritable {
            throw ConfigError.insecureFilePermissions(
                "配置文件 \(path) 权限过于开放（任意用户可写，权限：\(String(posixPermissions, radix: 8))）。" +
                "请执行：chmod o-w \"\(path)\""
            )
        }
    }

    /// Creates a sample configuration file at the specified path.
    /// Returns false when a file is already there — an existing config is never overwritten.
    @discardableResult
    static func createSampleConfig(at path: String? = nil) throws -> Bool {
        let configPath = path ?? defaultConfigPath
        let url = URL(fileURLWithPath: configPath)
        let directory = url.deletingLastPathComponent()

        if FileManager.default.fileExists(atPath: configPath) {
            return false
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let sampleYAML = """
        # ntfyx 配置文件
        # local_server_port: 9292  # 可选：启用本地 HTTP 服务器，供脚本触发通知
        servers:
          - url: https://ntfy.sh
            # token: your_token_here  # 可选，或使用 'ntfyx auth add' 存入钥匙串
            # allowed_schemes:  # 可选，默认为 [http, https]
            #   - https
            #   - myapp
            # allowed_domains:  # 可选，限制可打开链接的域名
            #   - example.com
            #   - "*.trusted.org"
            topics:
              - name: alerts
                icon_symbol: bell.fill
                # click_url: false  # 禁止点击通知时打开浏览器
                actions:
                  - title: Acknowledge
                    type: script
                    path: /usr/local/bin/ack-alert.sh

              - name: releases
                icon_symbol: arrow.down.circle.fill
                click_url: https://github.com/org/repo/releases  # 点击时打开的自定义链接

          - url: https://your-private-server.com
            token: your_private_token
            topics:
              - name: deployments
                icon_path: /Users/you/icons/deploy.png
                auto_run_script: /usr/local/bin/deploy-handler.sh

              - name: monitoring
                icon_symbol: server.rack
                silent: true
        """

        try sampleYAML.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// Retrieves the authentication token for a specific server
    func getAuthToken(forServer serverURL: String) -> String? {
        guard let config = config else { return nil }

        // Find the server config
        guard let serverConfig = config.servers.first(where: { $0.url == serverURL }) else {
            return nil
        }

        // Try Keychain first
        if let keychainToken = try? KeychainHelper.getToken(forServer: serverURL) {
            return keychainToken
        }

        // Fallback to config token
        return serverConfig.token
    }

    /// Finds a topic configuration for one specific server. The same topic name can
    /// exist on several servers with different settings, so the server is part of the key.
    func topicConfig(serverURL: String, topic topicName: String) -> TopicConfig? {
        return config?.topicConfig(serverURL: serverURL, topic: topicName)
    }

    /// Rewrites one server's topic list in the live config and persists it, keeping every
    /// other setting byte-for-byte. This is the write path behind the subscription actions in
    /// the history window; `ConfigWatcher` reloads the file afterwards, so callers must not
    /// also mutate `ConfigManager.shared.config` by hand.
    static func replacingTopics(
        serverURL: String,
        _ transform: (ServerConfig) -> ServerConfig
    ) throws {
        guard let config = shared.config else { throw ConfigError.fileNotFound }
        guard let index = config.servers.firstIndex(where: { $0.url == serverURL }) else {
            throw ConfigError.decodingError(NSError(
                domain: "ConfigManager",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "配置中没有服务器 \(serverURL)"]
            ))
        }

        var servers = config.servers
        servers[index] = transform(servers[index])
        let updated = AppConfig(servers: servers, localServerPort: config.localServerPort)
        try saveConfig(updated)
    }
}
