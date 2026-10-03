import Foundation

/// Unified error type for ntfy-mac application
/// 
/// This enum provides consistent error handling across the entire application.
/// It includes cases for config, keychain, server, script, notification, and local server errors.
/// 
/// Note: ConfigError (in Config.swift) and KeychainError (in KeychainHelper.swift) are 
/// preserved separately for backward compatibility. This NtfyError can wrap those errors
/// when needed for unified error handling.
enum NtfyError: Error, LocalizedError, Sendable {
    // MARK: - Config Errors
    
    case configNotFound(path: String)
    case configInvalid(reason: String)
    case configValidationFailed(field: String, reason: String)
    case insecureFilePermissions(String)
    case unknownConfigKeys(String)
    
    // MARK: - Keychain Errors
    
    case keychainInvalidData
    case keychainItemNotFound
    case keychainUnexpectedStatus(OSStatus)
    
    // MARK: - Server Errors
    
    case serverConnectionFailed(url: String, underlying: Error?)
    case serverAuthenticationFailed(url: String)
    case serverTimeout(url: String)
    case serverInvalidURL(url: String)
    
    // MARK: - Script Errors
    
    case scriptNotFound(path: String)
    case scriptNotExecutable(path: String)
    case scriptExecutionFailed(path: String, exitCode: Int32)
    case scriptTimeout(path: String)
    
    // MARK: - Notification Errors
    
    case notificationPermissionDenied
    case notificationDeliveryFailed(underlying: Error?)
    
    // MARK: - Local Server Errors
    
    case localServerPortInUse(port: UInt16)
    case localServerFailed(port: UInt16, underlying: Error?)
    
    // MARK: - Error Description
    
    var errorDescription: String? {
        switch self {
        // Config errors
        case .configNotFound(let path):
            return "未找到配置文件：\(path)"
        case .configInvalid(let reason):
            return "配置无效：\(reason)"
        case .configValidationFailed(let field, let reason):
            return "'\(field)' 校验失败：\(reason)"
        case .insecureFilePermissions(let message):
            return message
        case .unknownConfigKeys(let details):
            return "未知配置项：\n\(details)"
            
        // Keychain errors
        case .keychainInvalidData:
            return "提供给钥匙串操作的数据无效"
        case .keychainItemNotFound:
            return "钥匙串中未找到该条目"
        case .keychainUnexpectedStatus(let status):
            return "钥匙串错误：\(status)"
            
        // Server errors
        case .serverConnectionFailed(let url, let error):
            var message = "连接 \(url) 失败"
            if let error = error {
                message += ": \(error.localizedDescription)"
            }
            return message
        case .serverAuthenticationFailed(let url):
            return "\(url) 认证失败"
        case .serverTimeout(let url):
            return "\(url) 连接超时"
        case .serverInvalidURL(let url):
            return "服务器地址无效：\(url)"
            
        // Script errors
        case .scriptNotFound(let path):
            return "未找到脚本：\(path)"
        case .scriptNotExecutable(let path):
            return "脚本无执行权限：\(path)"
        case .scriptExecutionFailed(let path, let code):
            return "脚本 '\(path)' 以退出码 \(code) 结束"
        case .scriptTimeout(let path):
            return "脚本执行超时：\(path)"
            
        // Notification errors
        case .notificationPermissionDenied:
            return "通知权限被拒绝"
        case .notificationDeliveryFailed(let error):
            var message = "通知发送失败"
            if let error = error {
                message += ": \(error.localizedDescription)"
            }
            return message
            
        // Local server errors
        case .localServerPortInUse(let port):
            return "本地服务器端口 \(port) 已被占用"
        case .localServerFailed(let port, let error):
            var message = "本地服务器在端口 \(port) 上启动失败"
            if let error = error {
                message += ": \(error.localizedDescription)"
            }
            return message
        }
    }
    
    /// Recovery suggestion to help users resolve the error
    var recoverySuggestion: String? {
        switch self {
        case .configNotFound:
            return "运行 'ntfyx init' 创建示例配置"
        case .configInvalid, .configValidationFailed:
            return "请检查 config.yml 文件中的语法错误"
        case .insecureFilePermissions:
            return "运行 'chmod 600 ~/.config/ntfyx/config.yml' 加固配置文件权限"
        case .unknownConfigKeys:
            return "请从 config.yml 中移除未知配置项"
        case .keychainItemNotFound:
            return "运行 'ntfyx auth add <server> <token>' 存储认证信息"
        case .keychainUnexpectedStatus:
            return "请在系统设置中检查钥匙串访问权限"
        case .serverConnectionFailed:
            return "请检查服务器地址与网络连接"
        case .serverAuthenticationFailed:
            return "用 'ntfyx auth list' 核对认证令牌"
        case .serverTimeout:
            return "请确认服务器是否可达"
        case .serverInvalidURL:
            return "地址必须使用 http 或 https 协议"
        case .scriptNotFound:
            return "请确认脚本路径存在"
        case .scriptNotExecutable:
            return "运行 'chmod +x <script-path>' 赋予脚本执行权限"
        case .notificationPermissionDenied:
            return "前往 系统设置 → 通知 → ntfyx 开启通知"
        case .localServerPortInUse:
            return "请在 config.yml 中更换端口"
        default:
            return nil
        }
    }
}
