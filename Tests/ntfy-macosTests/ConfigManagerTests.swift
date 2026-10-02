import XCTest
@testable import ntfy_macos

final class ConfigManagerTests: XCTestCase {
    var tempConfigPath: String!

    override func setUp() {
        super.setUp()
        // Create a temporary file path for testing
        let tempDir = FileManager.default.temporaryDirectory
        tempConfigPath = tempDir.appendingPathComponent("test-config-\(UUID().uuidString).yml").path
    }

    override func tearDown() {
        // Clean up temporary file
        if let path = tempConfigPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        super.tearDown()
    }

    // MARK: - Loading config

    func testLoadConfigFileNotFound() {
        let manager = ConfigManager.shared
        XCTAssertThrowsError(try manager.loadConfig(from: "/nonexistent/path/config.yml")) { error in
            if case ConfigError.fileNotFound = error {
                // Expected
            } else {
                XCTFail("Expected fileNotFound error, got \(error)")
            }
        }
    }

    func testLoadValidConfig() throws {
        let yaml = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: alerts
                icon_symbol: bell.fill
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)

        let manager = ConfigManager.shared
        try manager.loadConfig(from: tempConfigPath)

        XCTAssertNotNil(manager.config)
        XCTAssertEqual(manager.config?.servers.count, 1)
        XCTAssertEqual(manager.config?.servers.first?.url, "https://ntfy.sh")
    }

    func testLoadConfigWithMultipleServers() throws {
        let yaml = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: public
                icon_symbol: globe
          - url: https://private.example.com
            token: secret123
            topics:
              - name: private
                icon_symbol: lock
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)

        let manager = ConfigManager.shared
        try manager.loadConfig(from: tempConfigPath)

        XCTAssertEqual(manager.config?.servers.count, 2)
        XCTAssertEqual(manager.config?.allTopics.count, 2)
        XCTAssertEqual(manager.config?.servers[1].token, "secret123")
    }

    func testLoadInvalidYaml() throws {
        let invalidYaml = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: [invalid
        """
        try invalidYaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)

        let manager = ConfigManager.shared
        XCTAssertThrowsError(try manager.loadConfig(from: tempConfigPath))
    }

    // MARK: - Topic lookup

    func testTopicConfigLookup() throws {
        let yaml = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: alerts
                icon_symbol: bell.fill
                silent: true
              - name: news
                icon_symbol: newspaper
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)

        let manager = ConfigManager.shared
        try manager.loadConfig(from: tempConfigPath)

        let alertsTopic = manager.topicConfig(serverURL: "https://ntfy.sh", topic: "alerts")
        XCTAssertNotNil(alertsTopic)
        XCTAssertEqual(alertsTopic?.iconSymbol, "bell.fill")
        XCTAssertEqual(alertsTopic?.silent, true)

        let newsTopic = manager.topicConfig(serverURL: "https://ntfy.sh", topic: "news")
        XCTAssertNotNil(newsTopic)
        XCTAssertEqual(newsTopic?.iconSymbol, "newspaper")

        let unknownTopic = manager.topicConfig(serverURL: "https://ntfy.sh", topic: "nonexistent")
        XCTAssertNil(unknownTopic)
    }

    /// The same topic name on different servers must resolve to each server's own config.
    func testTopicConfigLookupIsServerScoped() throws {
        let yaml = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: alerts
                icon_symbol: bell.fill
                silent: true
          - url: https://private.example.com
            topics:
              - name: alerts
                icon_symbol: exclamationmark.triangle
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)

        let manager = ConfigManager.shared
        try manager.loadConfig(from: tempConfigPath)

        let publicAlerts = manager.topicConfig(serverURL: "https://ntfy.sh", topic: "alerts")
        XCTAssertEqual(publicAlerts?.iconSymbol, "bell.fill")
        XCTAssertEqual(publicAlerts?.silent, true)

        let privateAlerts = manager.topicConfig(serverURL: "https://private.example.com", topic: "alerts")
        XCTAssertEqual(privateAlerts?.iconSymbol, "exclamationmark.triangle")
        XCTAssertNil(privateAlerts?.silent)

        // Unknown server → no config, even when the topic name exists elsewhere.
        XCTAssertNil(manager.topicConfig(serverURL: "https://other.example.com", topic: "alerts"))
    }

    func testServerLookupByURL() throws {
        let yaml = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: alerts
          - url: https://private.example.com
            allowed_domains: []
            topics:
              - name: alerts
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)

        let manager = ConfigManager.shared
        try manager.loadConfig(from: tempConfigPath)

        XCTAssertEqual(manager.config?.server(forURL: "https://ntfy.sh")?.allowedDomains, nil)
        XCTAssertEqual(manager.config?.server(forURL: "https://private.example.com")?.allowedDomains, [])
        XCTAssertNil(manager.config?.server(forURL: "https://missing.example.com"))
    }

    // MARK: - Sample config creation

    func testCreateSampleConfig() throws {
        let samplePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-config-\(UUID().uuidString).yml").path

        defer {
            try? FileManager.default.removeItem(atPath: samplePath)
        }

        XCTAssertTrue(try ConfigManager.createSampleConfig(at: samplePath))

        XCTAssertTrue(FileManager.default.fileExists(atPath: samplePath))

        let content = try String(contentsOfFile: samplePath, encoding: .utf8)
        XCTAssertTrue(content.contains("servers:"))
        XCTAssertTrue(content.contains("topics:"))
        XCTAssertTrue(content.contains("ntfy.sh"))
    }

    /// A user's existing config must survive a second `init` / sample-creation attempt.
    func testCreateSampleConfigNeverOverwritesExistingFile() throws {
        let existingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("existing-config-\(UUID().uuidString).yml").path
        let userConfig = "servers:\n  - url: https://mine.example\n    topics:\n      - name: private\n"
        try userConfig.write(toFile: existingPath, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(atPath: existingPath)
        }

        XCTAssertFalse(try ConfigManager.createSampleConfig(at: existingPath))

        let content = try String(contentsOfFile: existingPath, encoding: .utf8)
        XCTAssertEqual(content, userConfig)
    }

    func testCreateSampleConfigCreatesDirectory() throws {
        let nestedPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("nested-\(UUID().uuidString)")
            .appendingPathComponent("subdir")
            .appendingPathComponent("config.yml").path

        defer {
            // Clean up the entire nested directory
            let baseDir = (nestedPath as NSString).deletingLastPathComponent
            let parentDir = (baseDir as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: parentDir)
        }

        try ConfigManager.createSampleConfig(at: nestedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedPath))
    }
}
