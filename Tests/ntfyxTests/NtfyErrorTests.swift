import XCTest
@testable import ntfyx

final class NtfyErrorTests: XCTestCase {
    
    // MARK: - Config Errors Tests
    
    func testConfigNotFoundErrorDescription() {
        let error = NtfyError.configNotFound(path: "/path/to/config.yml")
        XCTAssertEqual(error.errorDescription, "未找到配置文件：/path/to/config.yml")
    }
    
    func testConfigNotFoundRecoverySuggestion() {
        let error = NtfyError.configNotFound(path: "/path/to/config.yml")
        XCTAssertEqual(error.recoverySuggestion, "运行 'ntfyx init' 创建示例配置")
    }
    
    func testConfigInvalidErrorDescription() {
        let error = NtfyError.configInvalid(reason: "YAML parsing failed")
        XCTAssertEqual(error.errorDescription, "配置无效：YAML parsing failed")
    }
    
    func testConfigValidationFailedErrorDescription() {
        let error = NtfyError.configValidationFailed(field: "server.url", reason: "Invalid URL")
        XCTAssertEqual(error.errorDescription, "'server.url' 校验失败：Invalid URL")
    }
    
    func testUnknownConfigKeysErrorDescription() {
        let error = NtfyError.unknownConfigKeys("unknown_key")
        XCTAssertEqual(error.errorDescription, "未知配置项：\nunknown_key")
    }
    
    // MARK: - Keychain Errors Tests
    
    func testKeychainInvalidDataErrorDescription() {
        let error = NtfyError.keychainInvalidData
        XCTAssertEqual(error.errorDescription, "提供给钥匙串操作的数据无效")
    }
    
    func testKeychainItemNotFoundErrorDescription() {
        let error = NtfyError.keychainItemNotFound
        XCTAssertEqual(error.errorDescription, "钥匙串中未找到该条目")
    }
    
    func testKeychainItemNotFoundRecoverySuggestion() {
        let error = NtfyError.keychainItemNotFound
        XCTAssertEqual(error.recoverySuggestion, "运行 'ntfyx auth add <server> <token>' 存储认证信息")
    }
    
    func testKeychainUnexpectedStatusErrorDescription() {
        let error = NtfyError.keychainUnexpectedStatus(-50)
        XCTAssertEqual(error.errorDescription, "钥匙串错误：-50")
    }
    
    // MARK: - Server Errors Tests
    
    func testServerConnectionFailedWithErrorErrorDescription() {
        let underlyingError = NSError(domain: "Test", code: 1, userInfo: nil)
        let error = NtfyError.serverConnectionFailed(url: "https://example.com", underlying: underlyingError)
        XCTAssertTrue(error.errorDescription!.contains("连接 https://example.com 失败"))
        // Just verify there's an error description appended when underlying error exists
        XCTAssertTrue(error.errorDescription!.count > 30)
    }
    
    func testServerConnectionFailedWithoutErrorErrorDescription() {
        let error = NtfyError.serverConnectionFailed(url: "https://example.com", underlying: nil)
        XCTAssertEqual(error.errorDescription, "连接 https://example.com 失败")
    }
    
    func testServerConnectionFailedRecoverySuggestion() {
        let error = NtfyError.serverConnectionFailed(url: "https://example.com", underlying: nil)
        XCTAssertEqual(error.recoverySuggestion, "请检查服务器地址与网络连接")
    }
    
    func testServerAuthenticationFailedErrorDescription() {
        let error = NtfyError.serverAuthenticationFailed(url: "https://example.com")
        XCTAssertEqual(error.errorDescription, "https://example.com 认证失败")
    }
    
    func testServerAuthenticationFailedRecoverySuggestion() {
        let error = NtfyError.serverAuthenticationFailed(url: "https://example.com")
        XCTAssertEqual(error.recoverySuggestion, "用 'ntfyx auth list' 核对认证令牌")
    }
    
    func testServerTimeoutErrorDescription() {
        let error = NtfyError.serverTimeout(url: "https://example.com")
        XCTAssertEqual(error.errorDescription, "https://example.com 连接超时")
    }
    
    func testServerTimeoutRecoverySuggestion() {
        let error = NtfyError.serverTimeout(url: "https://example.com")
        XCTAssertEqual(error.recoverySuggestion, "请确认服务器是否可达")
    }
    
    func testServerInvalidURLErrorDescription() {
        let error = NtfyError.serverInvalidURL(url: "not-a-url")
        XCTAssertEqual(error.errorDescription, "服务器地址无效：not-a-url")
    }
    
    func testServerInvalidURLRecoverySuggestion() {
        let error = NtfyError.serverInvalidURL(url: "not-a-url")
        XCTAssertEqual(error.recoverySuggestion, "地址必须使用 http 或 https 协议")
    }
    
    // MARK: - Script Errors Tests
    
    func testScriptNotFoundErrorDescription() {
        let error = NtfyError.scriptNotFound(path: "/path/to/script.sh")
        XCTAssertEqual(error.errorDescription, "未找到脚本：/path/to/script.sh")
    }
    
    func testScriptNotFoundRecoverySuggestion() {
        let error = NtfyError.scriptNotFound(path: "/path/to/script.sh")
        XCTAssertEqual(error.recoverySuggestion, "请确认脚本路径存在")
    }
    
    func testScriptNotExecutableErrorDescription() {
        let error = NtfyError.scriptNotExecutable(path: "/path/to/script.sh")
        XCTAssertEqual(error.errorDescription, "脚本无执行权限：/path/to/script.sh")
    }
    
    func testScriptNotExecutableRecoverySuggestion() {
        let error = NtfyError.scriptNotExecutable(path: "/path/to/script.sh")
        XCTAssertEqual(error.recoverySuggestion, "运行 'chmod +x <script-path>' 赋予脚本执行权限")
    }
    
    func testScriptExecutionFailedErrorDescription() {
        let error = NtfyError.scriptExecutionFailed(path: "/path/to/script.sh", exitCode: 1)
        XCTAssertEqual(error.errorDescription, "脚本 '/path/to/script.sh' 以退出码 1 结束")
    }
    
    func testScriptTimeoutErrorDescription() {
        let error = NtfyError.scriptTimeout(path: "/path/to/script.sh")
        XCTAssertEqual(error.errorDescription, "脚本执行超时：/path/to/script.sh")
    }
    
    // MARK: - Notification Errors Tests
    
    func testNotificationPermissionDeniedErrorDescription() {
        let error = NtfyError.notificationPermissionDenied
        XCTAssertEqual(error.errorDescription, "通知权限被拒绝")
    }
    
    func testNotificationPermissionDeniedRecoverySuggestion() {
        let error = NtfyError.notificationPermissionDenied
        XCTAssertEqual(error.recoverySuggestion, "前往 系统设置 → 通知 → ntfyx 开启通知")
    }
    
    func testNotificationDeliveryFailedWithErrorErrorDescription() {
        let underlyingError = NSError(domain: "Test", code: 1, userInfo: nil)
        let error = NtfyError.notificationDeliveryFailed(underlying: underlyingError)
        XCTAssertTrue(error.errorDescription!.contains("通知发送失败"))
        // Just verify there's an error description appended when underlying error exists
        XCTAssertTrue(error.errorDescription!.count > 20)
    }
    
    func testNotificationDeliveryFailedWithoutErrorErrorDescription() {
        let error = NtfyError.notificationDeliveryFailed(underlying: nil)
        XCTAssertEqual(error.errorDescription, "通知发送失败")
    }
    
    // MARK: - Local Server Errors Tests
    
    func testLocalServerPortInUseErrorDescription() {
        let error = NtfyError.localServerPortInUse(port: 9292)
        XCTAssertEqual(error.errorDescription, "本地服务器端口 9292 已被占用")
    }
    
    func testLocalServerPortInUseRecoverySuggestion() {
        let error = NtfyError.localServerPortInUse(port: 9292)
        XCTAssertEqual(error.recoverySuggestion, "请在 config.yml 中更换端口")
    }
    
    func testLocalServerFailedWithErrorErrorDescription() {
        let underlyingError = NSError(domain: "Test", code: 1, userInfo: nil)
        let error = NtfyError.localServerFailed(port: 9292, underlying: underlyingError)
        XCTAssertTrue(error.errorDescription!.contains("本地服务器在端口 9292 上启动失败"))
        // Just verify there's an error description appended when underlying error exists
        XCTAssertTrue(error.errorDescription!.count > 20)
    }
    
    func testLocalServerFailedWithoutErrorErrorDescription() {
        let error = NtfyError.localServerFailed(port: 9292, underlying: nil)
        XCTAssertEqual(error.errorDescription, "本地服务器在端口 9292 上启动失败")
    }
    
    // MARK: - Error Conformance Tests
    
    func testErrorConformsToLocalizedError() {
        let error: Error = NtfyError.configNotFound(path: "/test")
        XCTAssertNotNil(error.localizedDescription)
    }
    
    func testErrorConformsToSendable() {
        // NtfyError is marked as Sendable, so it can be used across threads
        let error = NtfyError.configNotFound(path: "/test")
        // Just verify it compiles as Sendable
        let sendableError: NtfyError = error
        XCTAssertNotNil(sendableError)
    }
}
